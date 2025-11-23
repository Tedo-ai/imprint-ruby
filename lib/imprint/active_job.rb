# frozen_string_literal: true

module Imprint
  module ActiveJob
    # Callback module to preserve trace context through ActiveJob execution
    module TraceContext
      extend ActiveSupport::Concern

      included do
        around_perform do |job, block|
          # Check if we have trace context from the job arguments or serialized data
          trace_id = job.try(:imprint_trace_id) || Thread.current[:imprint_trace_id]
          parent_span_id = job.try(:imprint_parent_span_id) || Thread.current[:imprint_parent_span_id]

          if trace_id
            span = Span.new(
              trace_id: trace_id,
              span_id: Span.generate_span_id,
              parent_id: parent_span_id,
              namespace: Imprint.configuration.service_name,
              name: "#{job.class.name}#perform",
              kind: "consumer",
              client: Imprint.client
            )

            span.set_attribute("messaging.system", "active_job")
            span.set_attribute("active_job.job_id", job.job_id)
            span.set_attribute("active_job.queue_name", job.queue_name)

            Imprint::Context.with_span(span) do
              begin
                block.call
                span.set_status(200)
              rescue Exception => e
                # Capture error on span BEFORE context is cleared
                span.record_error(e)
                span.set_status(500)
                raise e
              ensure
                span.finish
              end
            end
          else
            # No trace context, just run the job
            block.call
          end
        end

        # Capture trace context when job is enqueued
        before_enqueue do |job|
          if (current_span = Imprint::Context.current_span)
            job.instance_variable_set(:@imprint_trace_id, current_span.trace_id)
            job.instance_variable_set(:@imprint_parent_span_id, current_span.span_id)
          end
        end
      end

      def imprint_trace_id
        @imprint_trace_id
      end

      def imprint_parent_span_id
        @imprint_parent_span_id
      end

      # Serialize trace context with the job
      def serialize
        super.merge(
          "imprint_trace_id" => @imprint_trace_id,
          "imprint_parent_span_id" => @imprint_parent_span_id
        )
      end

      # Deserialize trace context from the job
      def deserialize(job_data)
        super
        @imprint_trace_id = job_data["imprint_trace_id"]
        @imprint_parent_span_id = job_data["imprint_parent_span_id"]
      end
    end
  end
end
