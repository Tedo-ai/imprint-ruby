# frozen_string_literal: true

# CORS middleware to allow browser requests with traceparent header
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins '*'
    resource '*',
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head],
      expose: ['traceparent', 'tracestate']
  end
end
