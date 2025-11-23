# frozen_string_literal: true

module Imprint
  module DelayedJob
    TRACE_ID_KEY = "imprint_trace_id"
    PARENT_SPAN_ID_KEY = "imprint_parent_span_id"

    # Wrapper that preserves trace context through YAML serialization
    class TracedPayload
      attr_accessor :payload, :trace_id, :parent_span_id

      def initialize(payload, trace_id: nil, parent_span_id: nil)
        @payload = payload
        @trace_id = trace_id
        @parent_span_id = parent_span_id
      end

      # Delegate perform to the wrapped payload
      def perform
        @payload.perform
      end

      # Support method_missing for duck typing compatibility
      def method_missing(method, *args, &block)
        if @payload.respond_to?(method)
          @payload.send(method, *args, &block)
        else
          super
        end
      end

      def respond_to_missing?(method, include_private = false)
        @payload.respond_to?(method, include_private) || super
      end
    end

    # Delayed::Job plugin for automatic trace propagation
    # Hooks into job enqueue and perform lifecycle events
    class Plugin < ::Delayed::Plugin
      callbacks do |lifecycle|
        # Around enqueue - captures trace context before job is queued
        lifecycle.around(:enqueue) do |job, *args, &block|
          Plugin.inject_trace_context(job)
          block.call(job, *args)
        end

        # Around perform - extracts trace context and creates span
        lifecycle.around(:perform) do |worker, job, *args, &block|
          Plugin.with_trace_span(job) do
            block.call(worker, job, *args)
          end
        end
      end

      class << self
        def inject_trace_context(job)
          current_span = Imprint::Context.current_span
          return unless current_span

          payload = job.payload_object

          # Wrap the payload with trace context
          wrapped = TracedPayload.new(
            payload,
            trace_id: current_span.trace_id,
            parent_span_id: current_span.span_id
          )

          # Replace the payload_object with our wrapper
          job.payload_object = wrapped
        rescue => e
          # Don't fail job enqueue if trace injection fails
        end

        def with_trace_span(job)
          return yield unless Imprint.client.enabled?

          trace_context = extract_trace_context(job)
          trace_id = trace_context[:trace_id] || Span.generate_trace_id
          parent_span_id = trace_context[:parent_span_id]

          span_name = extract_job_name(job)

          span = Span.new(
            trace_id: trace_id,
            span_id: Span.generate_span_id,
            parent_id: parent_span_id,
            namespace: Imprint.configuration.service_name,
            name: span_name,
            kind: "consumer",
            client: Imprint.client
          )

          span.set_attribute("messaging.system", "delayed_job")
          span.set_attribute("delayed_job.id", job.id.to_s) if job.respond_to?(:id)
          span.set_attribute("delayed_job.queue", job.queue.to_s) if job.respond_to?(:queue)
          span.set_attribute("delayed_job.priority", job.priority.to_s) if job.respond_to?(:priority)
          span.set_attribute("delayed_job.attempts", job.attempts.to_s) if job.respond_to?(:attempts)

          Imprint::Context.with_span(span) do
            begin
              yield
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
        end

        private

        def extract_trace_context(job)
          payload = job.payload_object

          # Check if payload is our wrapper
          if payload.is_a?(TracedPayload)
            return {
              trace_id: payload.trace_id,
              parent_span_id: payload.parent_span_id
            }
          end

          # Fallback: check for instance variable (legacy support)
          if payload.instance_variable_defined?(:@imprint_trace_context)
            ctx = payload.instance_variable_get(:@imprint_trace_context)
            return {
              trace_id: ctx[TRACE_ID_KEY],
              parent_span_id: ctx[PARENT_SPAN_ID_KEY]
            }
          end

          {}
        rescue => e
          {}
        end

        def extract_job_name(job)
          payload = job.payload_object

          # Unwrap if it's our TracedPayload wrapper
          actual_payload = payload.is_a?(TracedPayload) ? payload.payload : payload

          case actual_payload
          when ::Delayed::PerformableMethod
            # Format: ClassName#method_name (e.g., User#send_welcome_email)
            object = actual_payload.object
            method = actual_payload.method_name
            klass = object.is_a?(Class) ? object.name : object.class.name
            "#{klass}##{method}"
          when ::Delayed::PerformableMailer
            # Format: MailerClass#action (e.g., UserMailer#welcome)
            "#{actual_payload.object}##{actual_payload.method_name}"
          else
            # Custom job classes with perform method
            # Format: JobClass#perform (e.g., MyWorker#perform)
            "#{actual_payload.class.name}#perform"
          end
        rescue => e
          "UnknownJob#perform"
        end
      end
    end

    # Configure Delayed::Job with Imprint plugin
    def self.configure!
      return unless defined?(::Delayed::Worker)

      ::Delayed::Worker.plugins << Imprint::DelayedJob::Plugin
    end
  end
end
