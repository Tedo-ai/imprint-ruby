require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module ImprintRailsDemo
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Use Delayed::Job for background jobs
    config.active_job.queue_adapter = :delayed_job

    # Don't generate system test files
    config.generators.system_tests = nil

    # Autoload lib directory
    config.autoload_lib(ignore: %w[assets tasks])
  end
end
