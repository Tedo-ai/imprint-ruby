# Imprint Ruby Agent Configuration
# This connects the Rails app to the Imprint observability platform

Imprint.configure do |config|
  # API key for authentication
  config.api_key = ENV.fetch("IMPRINT_API_KEY", "imp_live_4fdmJeWtI5M3gAu5f9XSi6Ds")

  # Service name appears in the dashboard
  config.service_name = "imprint-rails-demo"

  # Ingest endpoint (production)
  config.ingest_url = ENV.fetch("IMPRINT_INGEST_URL", "https://api.imprint.cloud/v1/traces")

  # Enable debug logging for development
  config.debug = Rails.env.development?

  # Ignore health check endpoints
  config.ignore_paths = ["/up", "/health"]
end

# Note: Delayed::Job and Sidekiq are auto-configured by the Railtie

Rails.logger.info "[Imprint] Agent configured for #{Imprint.configuration.service_name}"
