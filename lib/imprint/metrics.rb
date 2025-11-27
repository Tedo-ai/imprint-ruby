# frozen_string_literal: true

module Imprint
  # Metrics collector for Ruby runtime statistics.
  #
  # The collector periodically samples runtime statistics (memory, GC, threads)
  # and emits them as gauge events that can be visualized in the Imprint dashboard.
  #
  # Usage:
  #
  #   # In config/initializers/imprint.rb
  #   Imprint::Metrics.start
  #
  #   # Or with custom interval (default: 60 seconds)
  #   Imprint::Metrics.start(interval: 30)
  #
  #   # To stop collecting metrics
  #   Imprint::Metrics.stop
  #
  class Metrics
    class << self
      attr_accessor :collector

      # Start collecting runtime metrics at the specified interval.
      # @param interval [Integer] Collection interval in seconds (default: 60)
      def start(interval: 60)
        return if @collector&.running?

        @collector = Collector.new(interval: interval)
        @collector.start
      end

      # Stop collecting runtime metrics.
      def stop
        @collector&.stop
        @collector = nil
      end

      # Check if the collector is running.
      def running?
        @collector&.running? || false
      end
    end

    # Internal collector class that manages the background thread.
    class Collector
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
        warn "[Imprint::Metrics] Error in collector: #{e.message}"
      end

      def collect_metrics
        return unless Imprint.client&.enabled?

        # Memory metrics (RSS in bytes)
        if (rss = get_process_memory_rss)
          Imprint.record_gauge("process.runtime.ruby.mem.rss", rss)
        end

        # GC statistics
        gc_stats = GC.stat
        Imprint.record_gauge("process.runtime.ruby.gc.count", gc_stats[:count])
        Imprint.record_gauge("process.runtime.ruby.gc.heap_allocated_pages", gc_stats[:heap_allocated_pages])
        Imprint.record_gauge("process.runtime.ruby.gc.heap_sorted_length", gc_stats[:heap_sorted_length])
        Imprint.record_gauge("process.runtime.ruby.gc.heap_live_slots", gc_stats[:heap_live_slots])
        Imprint.record_gauge("process.runtime.ruby.gc.heap_free_slots", gc_stats[:heap_free_slots])
        Imprint.record_gauge("process.runtime.ruby.gc.total_allocated_objects", gc_stats[:total_allocated_objects])
        Imprint.record_gauge("process.runtime.ruby.gc.total_freed_objects", gc_stats[:total_freed_objects])
        Imprint.record_gauge("process.runtime.ruby.gc.malloc_increase_bytes", gc_stats[:malloc_increase_bytes])

        # Minor/major GC counts (Ruby 2.1+)
        if gc_stats[:minor_gc_count]
          Imprint.record_gauge("process.runtime.ruby.gc.minor_gc_count", gc_stats[:minor_gc_count])
        end
        if gc_stats[:major_gc_count]
          Imprint.record_gauge("process.runtime.ruby.gc.major_gc_count", gc_stats[:major_gc_count])
        end

        # Thread count
        Imprint.record_gauge("process.runtime.ruby.threads.count", Thread.list.size)

        # Object space stats (can be expensive, so we limit what we collect)
        Imprint.record_gauge("process.runtime.ruby.objects.count", ObjectSpace.count_objects[:TOTAL])
      rescue => e
        warn "[Imprint::Metrics] Error collecting metrics: #{e.message}"
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
      rescue => e
        nil
      end
    end
  end
end
