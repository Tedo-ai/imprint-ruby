# frozen_string_literal: true

require "logger"

module Imprint
  # A Logger implementation that creates event spans for log entries.
  # Drop-in replacement for Appsignal::Logger.
  #
  # Usage:
  #   logger = Imprint::Logger.new("MyApp")
  #   logger.info("User logged in")
  #   logger.error("Payment failed")
  #
  # Each log call creates an event span linked to the current trace.
  #
  class Logger < ::Logger
    # Log levels that generate event spans
    TRACED_LEVELS = %i[debug info warn error fatal unknown].freeze

    # Maximum message length for span name (longer messages use "log" as name)
    MAX_NAME_LENGTH = 50

    attr_reader :logger_name

    def initialize(name = "imprint", logdev = $stdout, **options)
      @logger_name = name.to_s
      @fallback_logger = options.delete(:fallback_logger)

      super(logdev, **options)
    end

    # Override add to intercept all log calls
    def add(severity, message = nil, progname = nil, &block)
      # Get the actual message
      if message.nil?
        if block_given?
          message = yield
        else
          message = progname
          progname = @logger_name
        end
      end

      severity ||= UNKNOWN
      level_name = severity_to_level(severity)

      # Create event span if we have an active trace
      create_log_event(level_name, message.to_s) if message

      # Call parent to actually log
      super
    end

    # Convenience method matching AppSignal's interface
    def log(level, message, attributes = {})
      severity = level_to_severity(level)
      add(severity, message)

      # Add extra attributes as a separate event if provided
      if attributes.any? && Imprint::Context.current_span
        Imprint.client.record_event(
          "log.attributes",
          attributes: attributes.merge(level: level.to_s, message: truncate(message, 500))
        )
      end
    end

    private

    def create_log_event(level, message)
      return unless Imprint.client.enabled?

      current_span = Imprint::Context.current_span

      # Determine span name - use message if short, otherwise "log"
      span_name = if message.length <= MAX_NAME_LENGTH
        "log: #{message}"
      else
        "log.#{level}"
      end

      attributes = {
        "log.level" => level.to_s,
        "log.message" => truncate(message, 2048),
        "log.logger" => @logger_name
      }

      # Add trace context if available
      if current_span
        attributes["trace_id"] = current_span.trace_id
      end

      Imprint.client.record_event(span_name, attributes: attributes)
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

    def level_to_severity(level)
      case level.to_sym
      when :debug then DEBUG
      when :info then INFO
      when :warn then WARN
      when :error then ERROR
      when :fatal then FATAL
      else UNKNOWN
      end
    end

    def truncate(str, max_length)
      return str if str.length <= max_length

      "#{str[0, max_length - 3]}..."
    end
  end
end
