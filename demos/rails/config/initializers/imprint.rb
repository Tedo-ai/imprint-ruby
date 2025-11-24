# Imprint Ruby Agent Configuration
# This connects the Rails app to the Imprint observability platform

Imprint.configure do |config|
  # API key for authentication
  config.api_key = ENV.fetch("IMPRINT_API_KEY", "imp_live_00000000000000000")

  # Service name for HTTP requests (web namespace)
  config.service_name = "web"

  # Separate namespace for background jobs
  config.job_namespace = "worker"

  # Ingest endpoint (production)
  config.ingest_url = ENV.fetch("IMPRINT_INGEST_URL", "https://api.imprint.cloud/v1/spans")

  # Enable debug logging for development
  config.debug = Rails.env.development?

  # Ignore health check endpoints
  config.ignore_paths = ["/up", "/health"]
end

# Note: Delayed::Job and Sidekiq are auto-configured by the Railtie

Rails.logger.info "[Imprint] Agent configured for #{Imprint.configuration.service_name}"
