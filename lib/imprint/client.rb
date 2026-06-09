# frozen_string_literal: true

require "socket"

module Imprint
  class Client
    def initialize(configuration)
      @config = configuration
      # Lock-free queues: each push/pop is atomic, so draining never races with a
      # concurrent enqueue (no lost-span window) and the structure is fork-safe.
      @span_queue = Thread::Queue.new
      @log_queue = Thread::Queue.new
      @stopped = false
      @worker_thread = nil
      @worker_pid = nil
      @lifecycle_mutex = Mutex.new # guards worker (re)start, including across fork
      @dropped_spans = Concurrent::AtomicFixnum.new(0)
      @dropped_logs = Concurrent::AtomicFixnum.new(0)
      @last_drop_log = 0

      # Wake channel for the export worker. Reaching batch_size SIGNALS the
      # worker instead of flushing on the caller thread — exports must never
      # block the request thread (see the ASYNC EXPORT RULE in the README and
      # the imprint SDK docs). @flush_requested makes the signal lossless: if it
      # is set before the worker starts waiting, the worker flushes immediately
      # rather than sleeping a full flush_interval.
      @flush_mutex = Mutex.new
      @flush_cv = ConditionVariable.new
      @flush_requested = false

      if @config.debug
        puts "[Imprint] Initializing client..."
        puts "[Imprint]   API Key: #{@config.api_key&.slice(0, 20)}..."
        puts "[Imprint]   Ingest URL: #{@config.ingest_url}"
        puts "[Imprint]   Enabled: #{@config.enabled}"
        puts "[Imprint]   Valid: #{@config.valid?}"
      end

      if @config.enabled && @config.valid?
        start_worker
        puts "[Imprint] Worker started" if @config.debug
      else
        puts "[Imprint] Client NOT started (enabled=#{@config.enabled}, valid=#{@config.valid?})" if @config.debug
      end
    end

    # Start a new span with automatic context propagation
    def start_span(name, kind: "internal", parent: nil, &block)
      return yield_noop_span(&block) unless enabled?

      parent ||= Context.current_span
      trace_id = parent&.trace_id || Span.generate_trace_id
      parent_id = parent&.span_id

      span = Span.new(
        trace_id: trace_id,
        span_id: Span.generate_span_id,
        parent_id: parent_id,
        namespace: @config.service_name,
        name: name,
        kind: kind,
        client: self
      )

      if block_given?
        Context.with_span(span) do
          begin
            result = yield span
            span.finish
            result
          rescue => e
            span.record_error(e)
            span.finish
            raise
          end
        end
      else
        Context.current_span = span
        span
      end
    end

    # Record an instant event (0ns duration)
    def record_event(name, attributes: {})
      return unless enabled?

      parent = Context.current_span
      trace_id = parent&.trace_id || Span.generate_trace_id
      parent_id = parent&.span_id

      span = Span.new(
        trace_id: trace_id,
        span_id: Span.generate_span_id,
        parent_id: parent_id,
        namespace: @config.service_name,
        name: name,
        kind: "event",
        client: self
      )

      attributes.each { |k, v| span.set_attribute(k, v) }
      queue_span(span)
    end

    # Record a gauge metric value (numeric measurement at a point in time).
    # Gauges are used for values that can go up or down, such as:
    # - Memory usage (process.runtime.ruby.mem.rss)
    # - CPU percentage
    # - Queue depth
    # - Active connections
    #
    # The value is stored in the "metric.value" attribute, which the dashboard
    # uses to distinguish gauges from counters and render them as line charts.
    #
    # A "service.instance.id" attribute is automatically added using the hostname
    # if not already present, enabling multi-instance aggregation in the dashboard.
    #
    # @param name [String] The metric name (e.g., "process.runtime.ruby.mem.rss")
    # @param value [Numeric] The metric value
    # @param attributes [Hash] Additional attributes to attach
    def record_gauge(name, value, attributes: {})
      return unless enabled?

      parent = Context.current_span
      trace_id = parent&.trace_id || Span.generate_trace_id
      parent_id = parent&.span_id

      span = Span.new(
        trace_id: trace_id,
        span_id: Span.generate_span_id,
        parent_id: parent_id,
        namespace: @config.service_name,
        name: name,
        kind: "event",
        client: self
      )

      # Set the gauge value - this is what makes it a gauge vs counter
      span.set_attribute("metric.value", value.to_s)

      # Auto-inject service.instance.id (hostname) if not present
      # This enables multi-instance aggregation in the dashboard
      unless attributes.key?("service.instance.id") || attributes.key?(:"service.instance.id")
        span.set_attribute("service.instance.id", Socket.gethostname)
      end

      attributes.each { |k, v| span.set_attribute(k, v) }
      queue_span(span)
    end

    # Record a log entry with trace correlation
    # Logs are sent to the dedicated /v1/logs endpoint for optimized storage
    # and querying separate from spans.
    #
    # @param message [String] The log message
    # @param severity [String] Log severity: debug, info, warn, error, fatal
    # @param attributes [Hash] Additional attributes to attach
    def record_log(message, severity: "info", attributes: {})
      return unless enabled?

      # Get trace context if available
      current_span = Context.current_span
      trace_id = current_span&.trace_id || ""
      span_id = current_span&.span_id || ""

      log_entry = {
        timestamp: Time.now.utc.iso8601(9),
        trace_id: trace_id,
        span_id: span_id,
        severity: normalize_severity(severity),
        message: message.to_s,
        namespace: @config.service_name,
        attributes: attributes.transform_keys(&:to_s).transform_values(&:to_s).merge(
          "telemetry.sdk.name" => Imprint::SDK_NAME,
          "telemetry.sdk.version" => Imprint::VERSION,
          "telemetry.sdk.language" => Imprint::SDK_LANGUAGE
        )
      }

      queue_log(log_entry)
    end

    # Queue a log entry for batch sending. Non-blocking: never performs HTTP on
    # the caller thread. Reaching batch_size wakes the worker; it does the I/O.
    def queue_log(log_entry)
      return unless enabled?

      ensure_worker_for_process!
      if @log_queue.size >= @config.buffer_size
        @dropped_logs.increment # backpressure: drop, don't grow unbounded
        return
      end
      @log_queue << log_entry
      maybe_wake(@log_queue.size)
    end

    # Queue a span for batch sending. Non-blocking: never performs HTTP on the
    # caller (request) thread. Reaching batch_size wakes the worker, which owns
    # all exports — so a high-span request is never penalised with inline POSTs.
    def queue_span(span)
      return unless enabled?

      ensure_worker_for_process!
      if @span_queue.size >= @config.buffer_size
        @dropped_spans.increment # backpressure: drop, don't grow unbounded
        return
      end
      @span_queue << span
      maybe_wake(@span_queue.size)
    end

    # Shutdown the client and flush remaining spans and logs. The final flush
    # runs synchronously here on purpose — this is process teardown, not a
    # request thread.
    def shutdown(timeout: 5)
      @stopped = true
      wake_worker
      @worker_thread&.join(timeout)
      @worker_thread&.kill if @worker_thread&.alive?
      flush_sync
      flush_logs_sync
    end

    def enabled?
      @config.enabled && @config.valid? && !@stopped
    end

    # Counts of items dropped because the buffer was full (backpressure). Surface
    # these as an ops gauge so "ingest can't keep up" is visible, not silent loss.
    def dropped_spans_count
      @dropped_spans.value
    end

    def dropped_logs_count
      @dropped_logs.value
    end

    private

    def yield_noop_span
      noop = NoopSpan.new
      Context.with_span(noop) { yield noop }
    end

    # Fork-safety. A Thread does not survive fork() — only the forking thread is
    # copied — so on a preloading server (Puma preload_app! + workers) the client
    # is built in the master and every forked worker would have a DEAD
    # @worker_thread and never export (silent telemetry loss). Lazily (re)start
    # the worker the first time we enqueue in a new process. Cheap fast-path when
    # already healthy in this process.
    def ensure_worker_for_process!
      return unless @config.enabled && @config.valid?
      return if @worker_pid == Process.pid && @worker_thread&.alive?

      @lifecycle_mutex.synchronize do
        return if @worker_pid == Process.pid && @worker_thread&.alive?

        if @worker_pid && @worker_pid != Process.pid
          # We are in a fork. Inherited queues hold the PARENT's unsent items (the
          # parent sends its own copy) and the inherited wake state is stale —
          # reset to clean per-process state so the child never double-sends.
          @span_queue = Thread::Queue.new
          @log_queue = Thread::Queue.new
          @flush_mutex = Mutex.new
          @flush_cv = ConditionVariable.new
          @flush_requested = false
        end
        start_worker
      end
    end

    # Wake the export worker. Cheap, non-blocking. Fast-path: skip the lock if a
    # flush is already pending (benign race; the flush_interval wait backstops).
    def wake_worker
      return if @flush_requested

      @flush_mutex.synchronize do
        @flush_requested = true
        @flush_cv.signal
      end
    end

    # Wake at most once per batch_size worth of items rather than on every
    # enqueue past the threshold — bounds wake latency to one batch without
    # per-span @flush_mutex contention on high-span (700+) requests.
    def maybe_wake(size)
      wake_worker if size.positive? && (size % @config.batch_size).zero?
    end

    def start_worker
      @worker_pid = Process.pid
      @worker_thread = Thread.new do
        until @stopped
          begin
            # Wait for a wake signal OR up to flush_interval, whichever comes
            # first. The @flush_requested flag prevents a lost wake-up: if a
            # producer signalled before we got here, skip the wait and flush now.
            @flush_mutex.synchronize do
              @flush_cv.wait(@flush_mutex, @config.flush_interval) unless @flush_requested
              @flush_requested = false
            end
            break if @stopped

            flush_sync
            flush_logs_sync
            log_drops
          rescue => e
            debug_log("Worker error: #{e.class} - #{e.message}")
            # Never let the worker die on a transient error.
          end
        end
      end
    end

    # Drain a queue without blocking: pop until empty. A push that arrives after
    # we stop simply rides the next flush — no lost-span race (each pop is atomic,
    # unlike the old to_a + clear pair).
    def drain_queue(queue)
      items = []
      loop do
        items << queue.pop(true)
      rescue ThreadError
        break
      end
      items
    end

    def flush_sync
      spans = drain_queue(@span_queue)
      return if spans.empty?

      # Chunk the drain so a backlog never becomes one oversized POST that exceeds
      # the ingest payload limit.
      spans.each_slice(@config.batch_size) { |chunk| send_batch(chunk) }
    end

    def flush_logs_sync
      logs = drain_queue(@log_queue)
      return if logs.empty?

      logs.each_slice(@config.batch_size) { |chunk| send_logs_batch(chunk) }
    end

    # Surface overflow drops in debug mode (only when the count changes).
    def log_drops
      total = @dropped_spans.value + @dropped_logs.value
      return if total == @last_drop_log

      @last_drop_log = total
      debug_log("dropped on overflow: spans=#{@dropped_spans.value} logs=#{@dropped_logs.value}")
    end

    def send_batch(spans)
      uri = URI(@config.ingest_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      if http.use_ssl?
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        # Disable CRL checking which can fail with Let's Encrypt certs
        http.verify_callback = ->(_preverify_ok, store_context) {
          # Accept if cert is valid, skip CRL errors (error code 3)
          store_context.error == 0 || store_context.error == 3
        }
      end
      http.open_timeout = 5
      http.read_timeout = 5

      request = Net::HTTP::Post.new(uri.path)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@config.api_key}"
      request.body = spans.map(&:to_h).to_json

      debug_log("Sending #{spans.size} spans to #{@config.ingest_url}")
      response = http.request(request)
      debug_log("Response: #{response.code} #{response.message}")
      response
    rescue => e
      debug_log("Error sending spans: #{e.class} - #{e.message}")
      # Silently fail to avoid impacting the application
    end

    def send_logs_batch(logs)
      # Build logs URL from ingest URL (replace /v1/spans with /v1/logs)
      logs_url = @config.ingest_url.sub("/v1/spans", "/v1/logs")
      uri = URI(logs_url)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      if http.use_ssl?
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.verify_callback = ->(_preverify_ok, store_context) {
          store_context.error == 0 || store_context.error == 3
        }
      end
      http.open_timeout = 5
      http.read_timeout = 5

      request = Net::HTTP::Post.new(uri.path)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@config.api_key}"
      request.body = logs.to_json

      debug_log("Sending #{logs.size} logs to #{logs_url}")
      response = http.request(request)
      debug_log("Response: #{response.code} #{response.message}")
      response
    rescue => e
      debug_log("Error sending logs: #{e.class} - #{e.message}")
      # Silently fail to avoid impacting the application
    end

    def normalize_severity(severity)
      case severity.to_s.downcase
      when "debug", "trace"
        "debug"
      when "info", "information"
        "info"
      when "warn", "warning"
        "warn"
      when "error", "err"
        "error"
      when "fatal", "critical", "panic"
        "fatal"
      else
        "info"
      end
    end

    def debug_log(message)
      return unless @config.debug
      puts "[Imprint] #{message}"
    end
  end

  # NoopSpan for when tracing is disabled
  class NoopSpan
    attr_accessor :trace_id, :span_id, :parent_id, :status_code, :error_data,
                  :attributes, :name, :namespace

    def initialize
      @trace_id = nil
      @span_id = nil
      @parent_id = nil
      @status_code = 200
      @error_data = nil
      @attributes = {}
      @name = nil
      @namespace = nil
    end

    def finish; end
    def set_attribute(key, value); end
    def record_error(error); end
    def set_status(code); end
    def set_name(name); end
    def set_namespace(namespace); end
    def merge_attributes(attrs); end
    def root?; true; end
    alias_method :end, :finish
  end
end
