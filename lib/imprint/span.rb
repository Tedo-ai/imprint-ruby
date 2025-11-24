# frozen_string_literal: true

module Imprint
  class Span
    attr_reader :trace_id, :span_id, :parent_id, :kind, :start_time
    attr_accessor :status_code, :error_data, :attributes, :name, :namespace

    def initialize(trace_id:, span_id:, namespace:, name:, kind:, parent_id: nil, client: nil)
      @trace_id = trace_id
      @span_id = span_id
      @parent_id = parent_id
      @namespace = namespace
      @name = name
      @kind = kind
      @start_time = Time.now.utc
      @status_code = 200
      @error_data = nil
      @attributes = {}
      @client = client
      @ended = false
      @mutex = Mutex.new
    end

    # End the span and queue it for sending
    def finish
      @mutex.synchronize do
        return if @ended

        @ended = true
        @duration_ns = ((Time.now.utc - @start_time) * 1_000_000_000).to_i
        @client&.queue_span(self)
      end
    end

    alias_method :end, :finish

    # Set an attribute on the span
    def set_attribute(key, value)
      @mutex.synchronize do
        @attributes[key.to_s] = value.to_s
      end
    end

    # Record an error on the span
    def record_error(error)
      return unless error

      @mutex.synchronize do
        @error_data = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
        @status_code = 500 if @status_code < 400
      end
    end

    # Set the HTTP status code
    def set_status(code)
      @mutex.synchronize do
        @status_code = code.to_i
      end
    end

    # Set the span name (thread-safe)
    def set_name(new_name)
      @mutex.synchronize do
        @name = new_name.to_s
      end
    end

    # Set the span namespace (thread-safe)
    def set_namespace(new_namespace)
      @mutex.synchronize do
        @namespace = new_namespace.to_s
      end
    end

    # Merge multiple attributes at once (thread-safe)
    def merge_attributes(attrs)
      return unless attrs.is_a?(Hash)

      @mutex.synchronize do
        attrs.each do |key, value|
          @attributes[key.to_s] = value.to_s
        end
      end
    end

    # Check if this is a root span (no parent)
    def root?
      @parent_id.nil?
    end

    # Convert to hash for JSON serialization
    def to_h
      # Merge SDK metadata into attributes (OpenTelemetry Semantic Conventions)
      merged_attributes = @attributes.merge(
        "telemetry.sdk.name" => Imprint::SDK_NAME,
        "telemetry.sdk.version" => Imprint::VERSION,
        "telemetry.sdk.language" => Imprint::SDK_LANGUAGE
      )

      {
        trace_id: @trace_id,
        span_id: @span_id,
        parent_id: @parent_id,
        namespace: @namespace,
        name: @name,
        kind: @kind,
        start_time: @start_time.iso8601(9),
        duration_ns: (@duration_ns || 0).to_s,  # String for Go BigInt precision
        status_code: @status_code,
        error_data: @error_data,
        attributes: merged_attributes
      }.compact
    end

    def to_json(*args)
      to_h.to_json(*args)
    end

    # Class methods for ID generation
    class << self
      def generate_trace_id
        SecureRandom.hex(16) # 32 character hex string
      end

      def generate_span_id
        SecureRandom.hex(8) # 16 character hex string
      end
    end
  end
end
