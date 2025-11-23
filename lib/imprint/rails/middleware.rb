# frozen_string_literal: true

require "ostruct"

module Imprint
  module Rails
    # Rack middleware that creates a root span for each request
    # and handles trace context propagation
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)

        # Skip ignored paths
        if Imprint.configuration.should_ignore?(request.path)
          return @app.call(env)
        end

        # Check for incoming traceparent header (W3C Trace Context)
        parent_span = extract_trace_context(env)
        trace_id = parent_span&.trace_id || Span.generate_trace_id
        parent_id = parent_span&.span_id

        span_name = "#{request.request_method} #{request.path}"

        span = Span.new(
          trace_id: trace_id,
          span_id: Span.generate_span_id,
          parent_id: parent_id,
          namespace: Imprint.configuration.service_name,
          name: span_name,
          kind: "server",
          client: Imprint.client
        )

        # Store span in env for access by other middleware/controllers
        env["imprint.span"] = span
        env["imprint.trace_id"] = trace_id
        env["imprint.span_id"] = span.span_id

        Context.with_span(span) do
          status, headers, response = @app.call(env)

          span.set_status(status)
          span.set_attribute("http.method", request.request_method)
          span.set_attribute("http.url", request.url)
          span.set_attribute("http.status_code", status)

          if status >= 500
            span.record_error("HTTP #{status}")
          end

          span.finish

          [status, headers, response]
        end
      rescue => e
        span&.record_error(e)
        span&.finish
        raise
      end

      private

      # Extract W3C traceparent header
      # Format: 00-traceid-spanid-flags
      def extract_trace_context(env)
        traceparent = env["HTTP_TRACEPARENT"]
        return nil unless traceparent

        parts = traceparent.split("-")
        return nil unless parts.length == 4

        # Create a dummy parent span with trace context
        OpenStruct.new(
          trace_id: parts[1],
          span_id: parts[2]
        )
      end
    end
  end
end
