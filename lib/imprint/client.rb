# frozen_string_literal: true

require "socket"

module Imprint
  class Client
    def initialize(configuration)
      @config = configuration
      @buffer = Concurrent::Array.new
      @mutex = Mutex.new
      @stopped = false
      @worker_thread = nil

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

    # Queue a span for batch sending
    def queue_span(span)
      return unless enabled?

      if @buffer.size < @config.buffer_size
        @buffer << span
        flush_sync if @buffer.size >= @config.batch_size
      end
      # Drop span if buffer is full (avoid memory issues)
    end

    # Shutdown the client and flush remaining spans
    def shutdown(timeout: 5)
      @stopped = true
      @worker_thread&.kill
      flush_sync
    end

    def enabled?
      @config.enabled && @config.valid? && !@stopped
    end

    private

    def yield_noop_span
      noop = NoopSpan.new
      Context.with_span(noop) { yield noop }
    end

    def start_worker
      @worker_thread = Thread.new do
        loop do
          sleep @config.flush_interval
          flush_sync unless @stopped
        rescue => e
          # Log error but don't crash the worker
        end
      end
    end

    def flush_sync
      spans_to_send = []
      @mutex.synchronize do
        return if @buffer.empty?

        spans_to_send = @buffer.to_a
        @buffer.clear
      end

      send_batch(spans_to_send) if spans_to_send.any?
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
