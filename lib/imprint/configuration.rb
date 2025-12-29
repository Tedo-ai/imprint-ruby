# frozen_string_literal: true

module Imprint
  class Configuration
    attr_accessor :api_key, :service_name, :job_namespace, :ingest_url, :enabled,
                  :ignore_paths, :ignore_prefixes, :ignore_extensions,
                  :batch_size, :flush_interval, :buffer_size, :debug

    def initialize
      @api_key = ENV["IMPRINT_API_KEY"]
      @service_name = ENV["IMPRINT_SERVICE_NAME"] || "ruby-app"
      @job_namespace = ENV["IMPRINT_JOB_NAMESPACE"] # nil means use service_name
      @ingest_url = ENV["IMPRINT_INGEST_URL"] || "http://localhost:8080/v1/spans"
      @enabled = true
      @debug = ENV["IMPRINT_DEBUG"] == "true"

      # Filter rules
      @ignore_paths = []
      @ignore_prefixes = ["/assets/", "/packs/"]
      @ignore_extensions = %w[.css .js .png .jpg .jpeg .gif .ico .svg .woff .woff2 .ttf .eot .map]

      # Batching configuration
      @batch_size = 100
      @flush_interval = 5 # seconds
      @buffer_size = 1000
    end

    # Returns the metrics ingest URL derived from ingest_url
    def metrics_url
      @ingest_url.sub("/v1/spans", "/v1/metrics")
    end

    # Returns the namespace to use for background jobs
    def effective_job_namespace
      @job_namespace || @service_name
    end

    def valid?
      !api_key.nil? && !api_key.empty?
    end

    def should_ignore?(path)
      return true if ignore_paths.include?(path)
      return true if ignore_prefixes.any? { |prefix| path.start_with?(prefix) }
      return true if ignore_extensions.any? { |ext| path.end_with?(ext) }

      false
    end
  end
end
