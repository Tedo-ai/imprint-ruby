# frozen_string_literal: true

module Imprint
  # View helper for injecting trace context into HTML pages
  # This allows the browser agent to connect frontend traces to backend traces
  module ViewHelper
    # Generates meta tags with the current trace and span IDs
    #
    # Usage in application.html.erb:
    #   <%= imprint_meta_tags %>
    #
    # Output:
    #   <meta name="imprint-trace-id" content="abc123...">
    #   <meta name="imprint-span-id" content="def456...">
    #
    def imprint_meta_tags
      trace_id = Imprint::Context.current_trace_id
      span_id = Imprint::Context.current_span_id

      return "".html_safe unless trace_id && span_id

      tags = []
      tags << tag(:meta, name: "imprint-trace-id", content: trace_id)
      tags << tag(:meta, name: "imprint-span-id", content: span_id)

      safe_join(tags, "\n")
    end

    # Alternative method that returns a hash for use with content_tag or other helpers
    def imprint_trace_context
      {
        trace_id: Imprint::Context.current_trace_id,
        span_id: Imprint::Context.current_span_id
      }
    end
  end
end
