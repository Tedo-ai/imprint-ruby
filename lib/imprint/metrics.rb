# frozen_string_literal: true

require "json"
require "net/http"
require "socket"
require "concurrent"

module Imprint
  # Metrics API for recording application metrics.
  #
  # Three metric types are supported:
  #   - Counter: Monotonically increasing values (e.g., request count)
  #   - Gauge: Point-in-time values that can go up or down (e.g., memory usage)
  #   - Histogram: Distribution of values (e.g., request duration)
  #
  # Usage:
  #
  #   # Counters - for counting events
  #   Imprint::Metrics.increment("http.requests.total", labels: { method: "GET", status: "200" })
  #   Imprint::Metrics.increment("errors.total", 1, labels: { type: "validation" })
  #
  #   # Gauges - for current values
  #   Imprint::Metrics.gauge("queue.depth", queue.size, labels: { queue: "default" })
  #   Imprint::Metrics.gauge("cache.hit_rate", 0.95, labels: { cache: "redis" })
  #
  #   # Histograms - for timing and distributions
  #   Imprint::Metrics.histogram("http.request.duration", duration_ms, labels: { endpoint: "/api/users" })
  #   Imprint::Metrics.histogram("db.query.duration", query_time, labels: { table: "users" })
  #
  #   # Timing helper with block
  #   Imprint::Metrics.time("api.call.duration", labels: { service: "payment" }) do
  #     payment_service.charge(amount)
  #   end
  #
  # Runtime metrics collection:
  #
  #   # In config/initializers/imprint.rb
  #   Imprint::Metrics.start_runtime_collection(interval: 60)
  #
  #   # To stop collecting runtime metrics
  #   Imprint::Metrics.stop_runtime_collection
  #
  class Metrics
    # Default histogram buckets for latency (in milliseconds)
    DEFAULT_BUCKETS = [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000].freeze

    class << self
      attr_accessor :collector, :client

      # =========================================================================
      # Counter API
      # =========================================================================

      # Increment a counter metric.
      # Counters are monotonically increasing and reset on process restart.
      #
      # @param name [String] Metric name (e.g., "http.requests.total")
      # @param value [Numeric] Amount to increment by (default: 1)
      # @param labels [Hash] Key-value pairs for metric dimensions
      #
      # @example
      #   Imprint::Metrics.increment("http.requests.total")
      #   Imprint::Metrics.increment("orders.created", 1, labels: { region: "us-west" })
      #
      def increment(name, value = 1, labels: {})
        record_metric(name, :counter, value, labels: labels)
      end

      # Alias for increment
      alias_method :count, :increment

      # =========================================================================
      # Gauge API
      # =========================================================================

      # Record a gauge metric value.
      # Gauges represent a snapshot of a value at a point in time.
      #
      # @param name [String] Metric name (e.g., "process.memory.rss")
      # @param value [Numeric] The current value
      # @param labels [Hash] Key-value pairs for metric dimensions
      #
      # @example
      #   Imprint::Metrics.gauge("queue.depth", queue.size)
      #   Imprint::Metrics.gauge("cache.memory", cache.memory_usage, labels: { cache: "redis" })
      #
      def gauge(name, value, labels: {})
        record_metric(name, :gauge, value, labels: labels)
      end

      # Alias for gauge (AppSignal compatibility)
      alias_method :set_gauge, :gauge

      # =========================================================================
      # Histogram API
      # =========================================================================

      # Record a histogram observation.
      # Histograms track the distribution of values across predefined buckets.
      #
      # @param name [String] Metric name (e.g., "http.request.duration")
      # @param value [Numeric] The observed value
      # @param labels [Hash] Key-value pairs for metric dimensions
      # @param buckets [Array<Numeric>] Bucket boundaries (optional)
      #
      # @example
      #   Imprint::Metrics.histogram("http.request.duration", 42.5, labels: { method: "GET" })
      #
      def histogram(name, value, labels: {}, buckets: DEFAULT_BUCKETS)
        record_histogram(name, value, labels: labels, buckets: buckets)
      end

      # Record a timing observation in milliseconds.
      # Convenience method that calls histogram with time unit set.
      #
      # @param name [String] Metric name
      # @param value_ms [Numeric] Duration in milliseconds
      # @param labels [Hash] Key-value pairs for metric dimensions
      #
      def timing(name, value_ms, labels: {})
        histogram(name, value_ms, labels: labels.merge(unit: "ms"))
      end

      # Time a block and record the duration as a histogram.
      #
      # @param name [String] Metric name
      # @param labels [Hash] Key-value pairs for metric dimensions
      # @yield Block to time
      # @return Result of the block
      #
      # @example
      #   result = Imprint::Metrics.time("external.api.duration", labels: { service: "stripe" }) do
      #     Stripe::Charge.create(amount: 1000)
      #   end
      #
      def time(name, labels: {}, &block)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
        result = yield
        duration_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - start_time
        histogram(name, duration_ms, labels: labels.merge(unit: "ms"))
        result
      end

      # =========================================================================
      # Runtime Metrics Collection
      # =========================================================================

      # Start collecting runtime metrics at the specified interval.
      # @param interval [Integer] Collection interval in seconds (default: 60)
      def start_runtime_collection(interval: 60)
        return if @collector&.running?

        @collector = RuntimeCollector.new(interval: interval)
        @collector.start
      end

      # Alias for backward compatibility
      alias_method :start, :start_runtime_collection

      # Stop collecting runtime metrics.
      def stop_runtime_collection
        @collector&.stop
        @collector = nil
      end

      # Alias for backward compatibility
      alias_method :stop, :stop_runtime_collection

      # Check if the runtime collector is running.
      def running?
        @collector&.running? || false
      end

      # =========================================================================
      # Metrics Client Management
      # =========================================================================

      # Get or create the metrics client.
      def metrics_client
        @client ||= MetricsClient.new(Imprint.configuration)
      end

      # Flush all buffered metrics immediately.
      def flush
        metrics_client.flush
      end

      # Shutdown the metrics client.
      def shutdown(timeout: 5)
        @client&.shutdown(timeout: timeout)
        @client = nil
      end

      private

      def record_metric(name, type, value, labels: {})
        return unless Imprint.client&.enabled?

        metrics_client.record(
          name: name,
          type: type,
          value: value,
          labels: labels
        )
      end

      def record_histogram(name, value, labels: {}, buckets: DEFAULT_BUCKETS)
        return unless Imprint.client&.enabled?

        metrics_client.record_histogram(
          name: name,
          value: value,
          labels: labels,
          buckets: buckets
        )
      end
    end

    # =========================================================================
    # Metrics Client (handles batching and sending)
    # =========================================================================

    class MetricsClient
      def initialize(config)
        @config = config
        @buffer = Concurrent::Array.new
        @mutex = Mutex.new
        @stopped = false
        @worker_thread = nil
        @histogram_state = Concurrent::Hash.new # Track histogram state for aggregation

        start_worker if enabled?
      end

      def enabled?
        @config.enabled && @config.valid? && !@stopped
      end

      def record(name:, type:, value:, labels: {})
        return unless enabled?

        metric = {
          name: name,
          type: type.to_s,
          value: value.to_f,
          labels: normalize_labels(labels),
          timestamp: Time.now.utc.iso8601(3)
        }

        buffer_metric(metric)
      end

      def record_histogram(name:, value:, labels: {}, buckets: Metrics::DEFAULT_BUCKETS)
        return unless enabled?

        normalized_labels = normalize_labels(labels)
        key = [name, normalized_labels.sort.to_h].hash

        # Update histogram state (client-side aggregation for efficiency)
        @mutex.synchronize do
          state = @histogram_state[key] ||= {
            name: name,
            labels: normalized_labels,
            buckets: buckets,
            counts: Array.new(buckets.length + 1, 0),
            sum: 0.0,
            count: 0,
            min: Float::INFINITY,
            max: -Float::INFINITY
          }

          # Find bucket and increment count
          bucket_idx = buckets.find_index { |b| value <= b } || buckets.length
          state[:counts][bucket_idx] += 1
          state[:sum] += value
          state[:count] += 1
          state[:min] = [state[:min], value].min
          state[:max] = [state[:max], value].max
        end
      end

      def flush
        flush_counters_and_gauges
        flush_histograms
      end

      def shutdown(timeout: 5)
        @stopped = true
        @worker_thread&.kill
        flush
      end

      private

      def start_worker
        @worker_thread = Thread.new do
          loop do
            sleep @config.flush_interval
            flush unless @stopped
          rescue => e
            # Log error but don't crash the worker
          end
        end
      end

      def buffer_metric(metric)
        if @buffer.size < @config.buffer_size
          @buffer << metric
          flush_counters_and_gauges if @buffer.size >= @config.batch_size
        end
        # Drop metric if buffer is full (avoid memory issues)
      end

      def flush_counters_and_gauges
        metrics_to_send = []
        @mutex.synchronize do
          return if @buffer.empty?

          metrics_to_send = @buffer.to_a
          @buffer.clear
        end

        send_batch(metrics_to_send) if metrics_to_send.any?
      end

      def flush_histograms
        histograms_to_send = []
        @mutex.synchronize do
          return if @histogram_state.empty?

          @histogram_state.each do |_key, state|
            histograms_to_send << {
              name: state[:name],
              type: "histogram",
              value: 0, # Not used for histograms
              labels: state[:labels],
              timestamp: Time.now.utc.iso8601(3),
              histogram_buckets: state[:buckets],
              histogram_counts: state[:counts],
              sum: state[:sum],
              count: state[:count],
              min: state[:min] == Float::INFINITY ? 0 : state[:min],
              max: state[:max] == -Float::INFINITY ? 0 : state[:max]
            }
          end
          @histogram_state.clear
        end

        send_batch(histograms_to_send) if histograms_to_send.any?
      end

      def send_batch(metrics)
        uri = URI(@config.metrics_url)
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
        request.body = metrics.to_json

        debug_log("Sending #{metrics.size} metrics to #{@config.metrics_url}")
        response = http.request(request)
        debug_log("Response: #{response.code} #{response.message}")
        response
      rescue => e
        debug_log("Error sending metrics: #{e.class} - #{e.message}")
        # Silently fail to avoid impacting the application
      end

      def normalize_labels(labels)
        normalized = labels.transform_keys(&:to_s).transform_values(&:to_s)

        # Add service.instance.id if not present (for multi-instance aggregation)
        normalized["service.instance.id"] ||= Socket.gethostname
        normalized["service"] ||= @config.service_name

        normalized
      end

      def debug_log(message)
        return unless @config.debug
        puts "[Imprint::Metrics] #{message}"
      end
    end

    # =========================================================================
    # Runtime Collector (background thread for system metrics)
    # =========================================================================

    class RuntimeCollector
      attr_reader :interval

      def initialize(interval: 60)
        @interval = interval
        @thread = nil
        @stop_requested = false
        @mutex = Mutex.new
      end

      def start
        @mutex.synchronize do
          return if @thread&.alive?

          @stop_requested = false
          @thread = Thread.new { run_loop }
        end
      end

      def stop
        @mutex.synchronize do
          @stop_requested = true
        end
        @thread&.join(5) # Wait up to 5 seconds for thread to stop
        @thread = nil
      end

      def running?
        @thread&.alive? || false
      end

      private

      def run_loop
        # Collect immediately on start
        collect_metrics

        loop do
          sleep @interval
          break if @stop_requested

          collect_metrics
        end
      rescue => e
        # Log error but don't crash
        warn "[Imprint::Metrics] Error in runtime collector: #{e.message}"
      end

      def collect_metrics
        return unless Imprint.client&.enabled?

        # Memory metrics (RSS in bytes)
        if (rss = get_process_memory_rss)
          Metrics.gauge("process.runtime.ruby.mem.rss", rss)
        end

        # GC statistics
        gc_stats = GC.stat
        Metrics.gauge("process.runtime.ruby.gc.count", gc_stats[:count])
        Metrics.gauge("process.runtime.ruby.gc.heap_allocated_pages", gc_stats[:heap_allocated_pages])
        Metrics.gauge("process.runtime.ruby.gc.heap_sorted_length", gc_stats[:heap_sorted_length])
        Metrics.gauge("process.runtime.ruby.gc.heap_live_slots", gc_stats[:heap_live_slots])
        Metrics.gauge("process.runtime.ruby.gc.heap_free_slots", gc_stats[:heap_free_slots])
        Metrics.gauge("process.runtime.ruby.gc.total_allocated_objects", gc_stats[:total_allocated_objects])
        Metrics.gauge("process.runtime.ruby.gc.total_freed_objects", gc_stats[:total_freed_objects])
        Metrics.gauge("process.runtime.ruby.gc.malloc_increase_bytes", gc_stats[:malloc_increase_bytes])

        # Minor/major GC counts (Ruby 2.1+)
        if gc_stats[:minor_gc_count]
          Metrics.gauge("process.runtime.ruby.gc.minor_gc_count", gc_stats[:minor_gc_count])
        end
        if gc_stats[:major_gc_count]
          Metrics.gauge("process.runtime.ruby.gc.major_gc_count", gc_stats[:major_gc_count])
        end

        # Thread count
        Metrics.gauge("process.runtime.ruby.threads.count", Thread.list.size)

        # Object space stats
        Metrics.gauge("process.runtime.ruby.objects.count", ObjectSpace.count_objects[:TOTAL])
      rescue => e
        warn "[Imprint::Metrics] Error collecting runtime metrics: #{e.message}"
      end

      def get_process_memory_rss
        # Try different methods to get RSS depending on platform
        if File.exist?("/proc/self/status")
          # Linux: read from /proc
          File.read("/proc/self/status").match(/VmRSS:\s+(\d+)/) do |m|
            return m[1].to_i * 1024 # Convert from KB to bytes
          end
        end

        # macOS/BSD: use ps command
        if RUBY_PLATFORM.include?("darwin") || RUBY_PLATFORM.include?("bsd")
          output = `ps -o rss= -p #{Process.pid}`.strip
          return output.to_i * 1024 if output =~ /^\d+$/ # Convert from KB to bytes
        end

        # Fallback: try GetProcessMem gem if available
        if defined?(GetProcessMem)
          return GetProcessMem.new.bytes.to_i
        end

        nil
      rescue
        nil
      end
    end
  end
end
