# frozen_string_literal: true

require "logger"
require "json"

module Imprint
  # A Logger implementation that sends logs to Imprint while optionally
  # broadcasting to other loggers (like STDOUT or Rails' default logger).
  #
  # Designed to be a drop-in replacement for Ruby's Logger and compatible
  # with ActiveSupport::TaggedLogging.
  #
  # == Rails Logger
  #
  #   # config/initializers/imprint.rb
  #   imprint_logger = Imprint::Logger.new("rails")
  #   Rails.logger = ActiveSupport::TaggedLogging.new(imprint_logger)
  #
  # == Using multiple logging backends
  #
  #   # Send logs to both Imprint and Rails' default logger
  #   imprint_logger = Imprint::Logger.new("rails")
  #   imprint_logger.broadcast_to(Rails.logger)
  #   Rails.logger = ActiveSupport::TaggedLogging.new(imprint_logger)
  #
  # == Sidekiq Logger
  #
  #   Sidekiq.configure_server do |config|
  #     config.logger = Imprint::Logger.new("sidekiq")
  #     config.logger.broadcast_to(Logger.new($stdout))
  #   end
  #
  # == With default attributes
  #
  #   logger = Imprint::Logger.new("invoice_helper", attributes: { customer_id: @customer.id })
  #   logger.info("Generating invoice")  # includes customer_id automatically
  #
  # == With custom attributes per message
  #
  #   logger = Imprint::Logger.new("app")
  #   logger.info("User signed in", user_id: user.id, plan: "premium")
  #
  class Logger < ::Logger
    # Log format constants
    PLAINTEXT = :plaintext
    LOGFMT = :logfmt
    JSON = :json

    attr_reader :group, :default_attributes, :format
    attr_accessor :broadcast_targets

    # @param group [String] The log group/source name (e.g., "rails", "sidekiq", "app")
    # @param format [Symbol] Log format - PLAINTEXT, LOGFMT, or JSON (default: auto-detect)
    # @param attributes [Hash] Default attributes included in all log messages
    # @param logdev [IO, String] Where to write logs locally (default: nil, Imprint only)
    def initialize(group, format: nil, attributes: {}, logdev: nil, **options)
      @group = group.to_s
      @format = format
      @default_attributes = attributes.transform_keys(&:to_s)
      @broadcast_targets = []

      # If no logdev specified, use a null device (we send to Imprint, not local)
      super(logdev || File.open(File::NULL, "w"), **options)
    end

    # Broadcast log messages to another logger in addition to Imprint.
    # Useful for sending logs to both Imprint and STDOUT/Rails default logger.
    #
    # @param logger [Logger] The logger to broadcast to
    # @return [self]
    def broadcast_to(logger)
      @broadcast_targets << logger
      self
    end

    # Log a message with optional attributes.
    # Compatible with both Ruby Logger interface and AppSignal-style attributes.
    #
    # @param severity [Integer] Log severity level
    # @param message [String, nil] Log message
    # @param progname [String, nil] Program name
    # @param attributes [Hash] Additional attributes for this log entry
    def add(severity, message = nil, progname = nil, attributes: {}, &block)
      severity ||= UNKNOWN

      # Handle block form
      if message.nil?
        if block_given?
          message = yield
        else
          message = progname
          progname = @group
        end
      end

      return true if message.nil?

      # Send to Imprint
      send_to_imprint(severity, message.to_s, attributes)

      # Broadcast to other loggers
      @broadcast_targets.each do |target|
        target.add(severity, message, progname)
      end

      # Call parent for local logging (if logdev was specified)
      super(severity, message, progname)
    end

    # Convenience methods with attributes support
    def debug(message = nil, **attributes, &block)
      add(DEBUG, nil, message, attributes: attributes, &block)
    end

    def info(message = nil, **attributes, &block)
      add(INFO, nil, message, attributes: attributes, &block)
    end

    def warn(message = nil, **attributes, &block)
      add(WARN, nil, message, attributes: attributes, &block)
    end

    def error(message = nil, **attributes, &block)
      add(ERROR, nil, message, attributes: attributes, &block)
    end

    def fatal(message = nil, **attributes, &block)
      add(FATAL, nil, message, attributes: attributes, &block)
    end

    def unknown(message = nil, **attributes, &block)
      add(UNKNOWN, nil, message, attributes: attributes, &block)
    end

    private

    def send_to_imprint(severity, message, extra_attributes)
      return unless Imprint.client.enabled?

      level = severity_to_level(severity)
      parsed_attrs = parse_message_attributes(message)

      # Merge attributes: defaults < parsed from message < explicit attributes
      attributes = @default_attributes
        .merge(parsed_attrs)
        .merge(extra_attributes.transform_keys(&:to_s))

      # Add standard log attributes
      attributes["log.level"] = level.to_s
      attributes["log.group"] = @group
      attributes["log.message"] = truncate(message, 4096)

      # Add trace context if available
      if (current_span = Imprint::Context.current_span)
        attributes["trace_id"] = current_span.trace_id
        attributes["span_id"] = current_span.span_id
      end

      # Create span name
      span_name = "log.#{level}"

      Imprint.client.record_event(span_name, attributes: attributes)
    end

    def parse_message_attributes(message)
      return {} if message.nil? || message.empty?

      case detect_format(message)
      when JSON
        parse_json(message)
      when LOGFMT
        parse_logfmt(message)
      else
        {}
      end
    end

    def detect_format(message)
      return @format if @format

      # Auto-detect format
      stripped = message.strip
      if stripped.start_with?("{") && stripped.end_with?("}")
        JSON
      elsif stripped.include?("=") && stripped.match?(/\w+=\S+/)
        LOGFMT
      else
        PLAINTEXT
      end
    end

    def parse_json(message)
      ::JSON.parse(message)
    rescue ::JSON::ParserError
      {}
    end

    def parse_logfmt(message)
      attrs = {}
      # Match key=value or key="value with spaces"
      message.scan(/(\w+)=(?:"([^"]*)"|(\S+))/) do |key, quoted_val, unquoted_val|
        attrs[key] = quoted_val || unquoted_val
      end
      attrs
    end

    def severity_to_level(severity)
      case severity
      when DEBUG then :debug
      when INFO then :info
      when WARN then :warn
      when ERROR then :error
      when FATAL then :fatal
      else :unknown
      end
    end

    def truncate(str, max_length)
      return str if str.nil? || str.length <= max_length

      "#{str[0, max_length - 3]}..."
    end
  end
end
