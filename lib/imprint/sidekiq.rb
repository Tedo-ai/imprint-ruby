# frozen_string_literal: true

module Imprint
  module Sidekiq
    TRACE_ID_KEY = "imprint.trace_id"
    PARENT_SPAN_ID_KEY = "imprint.parent_span_id"

    # Client middleware - runs when a job is enqueued
    # Captures the current trace context and stores it in the job payload
    class ClientMiddleware
      def call(worker_class, job, queue, redis_pool)
        # Capture current trace context
        if (current_span = Imprint::Context.current_span)
          job[TRACE_ID_KEY] = current_span.trace_id
          job[PARENT_SPAN_ID_KEY] = current_span.span_id
        end

        yield
      end
    end

    # Server middleware - runs when a job is executed
    # Extracts trace context and creates a new span for the job
    class ServerMiddleware
      def call(worker, job, queue)
        return yield unless Imprint.client.enabled?

        trace_id = job[TRACE_ID_KEY] || Span.generate_trace_id
        parent_span_id = job[PARENT_SPAN_ID_KEY]

        job_class = job["wrapped"] || job["class"]
        span_name = "#{job_class}#perform"

        span = Span.new(
          trace_id: trace_id,
          span_id: Span.generate_span_id,
          parent_id: parent_span_id,
          namespace: Imprint.configuration.service_name,
          name: span_name,
          kind: "consumer",
          client: Imprint.client
        )

        span.set_attribute("messaging.system", "sidekiq")
        span.set_attribute("messaging.destination", queue)
        span.set_attribute("sidekiq.job_id", job["jid"])
        span.set_attribute("sidekiq.queue", queue)
        span.set_attribute("sidekiq.retry", job["retry"].to_s)

        Imprint::Context.with_span(span) do
          yield
          span.set_status(200)
          span.finish
        end
      rescue => e
        span&.record_error(e)
        span&.set_status(500)
        span&.finish
        raise
      end
    end

    # Configure Sidekiq with Imprint middleware
    def self.configure!
      return unless defined?(::Sidekiq)

      ::Sidekiq.configure_client do |config|
        config.client_middleware do |chain|
          chain.add Imprint::Sidekiq::ClientMiddleware
        end
      end

      ::Sidekiq.configure_server do |config|
        config.client_middleware do |chain|
          chain.add Imprint::Sidekiq::ClientMiddleware
        end

        config.server_middleware do |chain|
          chain.add Imprint::Sidekiq::ServerMiddleware
        end
      end
    end
  end
end
