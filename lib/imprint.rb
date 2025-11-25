# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "concurrent"

require_relative "imprint/version"
require_relative "imprint/configuration"
require_relative "imprint/span"
require_relative "imprint/client"
require_relative "imprint/context"
require_relative "imprint/traced_logger"

# Rails integration - always require, but it only activates when Rails is present
require_relative "imprint/railtie"

module Imprint
  class Error < StandardError; end

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
      @client = nil # Reset client when configuration changes
    end

    def client
      @client ||= Client.new(configuration)
    end

    # Convenience method to start a span
    def start_span(name, kind: "internal", parent: nil, &block)
      client.start_span(name, kind: kind, parent: parent, &block)
    end

    # Convenience method to record an event
    def record_event(name, attributes: {})
      client.record_event(name, attributes: attributes)
    end

    # Shutdown the client gracefully
    def shutdown(timeout: 5)
      @client&.shutdown(timeout: timeout)
    end

    # =========================================================================
    # Manual Instrumentation API (AppSignal compatibility)
    # =========================================================================

    # Send an error to Imprint, attaching it to the current root span.
    # If no span is active, creates a standalone error event.
    #
    # @param exception [Exception] The exception to record
    # @param tags [Hash] Additional attributes to attach
    #
    # Usage:
    #   begin
    #     risky_operation
    #   rescue => e
    #     Imprint.send_error(e, user_id: current_user.id)
    #     raise
    #   end
    #
    def send_error(exception, tags = {})
      return unless client.enabled?

      span = find_root_span

      if span
        span.record_error(exception)
        span.merge_attributes(stringify_tags(tags))
      else
        # No active span - create a standalone error event
        attributes = {
          "error.class" => exception.class.name,
          "error.message" => exception.message,
          "error.backtrace" => exception.backtrace&.first(10)&.join("\n")
        }.merge(stringify_tags(tags))

        client.record_event("error: #{exception.class.name}", attributes: attributes)
        log_outside_request("send_error called outside of request context")
      end
    end

    # Set the action name for the current root span.
    # Useful for dynamic routes or when Rails can't detect the action.
    #
    # @param name [String] The action name (e.g., "UsersController#show")
    #
    # Usage:
    #   Imprint.set_action("DynamicController##{params[:action]}")
    #
    def set_action(name)
      return unless client.enabled?

      span = find_root_span

      if span
        span.set_name(name.to_s)
      else
        log_outside_request("set_action called outside of request context")
      end
    end

    # Set the namespace for the current root span.
    # Useful for categorizing requests (e.g., "admin", "api", "web").
    #
    # @param name [String] The namespace name
    #
    # Usage:
    #   Imprint.set_namespace("admin")
    #
    def set_namespace(name)
      return unless client.enabled?

      span = find_root_span

      if span
        span.set_namespace(name.to_s)
      else
        log_outside_request("set_namespace called outside of request context")
      end
    end

    # Add custom attributes to the current root span.
    #
    # @param tags [Hash] Key-value pairs to attach
    #
    # Usage:
    #   Imprint.tag(user_id: current_user.id, plan: "premium")
    #
    def tag(tags = {})
      return unless client.enabled?

      span = find_root_span

      if span
        span.merge_attributes(stringify_tags(tags))
      else
        log_outside_request("tag called outside of request context")
      end
    end

    # Get the current trace ID (useful for logging correlation)
    #
    # @return [String, nil] The current trace ID or nil
    #
    def current_trace_id
      Context.current_trace_id
    end

    # Get the current span ID
    #
    # @return [String, nil] The current span ID or nil
    #
    def current_span_id
      Context.current_span_id
    end

    private

    # Find the root span by walking up the context.
    # For now, we return the current span since we don't track parent refs.
    # In most cases, the middleware creates the root span.
    def find_root_span
      span = Context.current_span
      return nil unless span

      # If we have a root span tracking mechanism, use it
      # For now, return the current span (which is typically the request span)
      span
    end

    def stringify_tags(tags)
      tags.transform_keys(&:to_s).transform_values(&:to_s)
    end

    def log_outside_request(message)
      # Log to STDERR in development, no-op in production
      return unless configuration.respond_to?(:debug) && configuration.debug

      warn "[Imprint] #{message}"
    end
  end
end
