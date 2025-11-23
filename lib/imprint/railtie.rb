# frozen_string_literal: true

# Only define the Railtie when Rails is present
if defined?(Rails::Railtie)
  require_relative "rails/subscriber"
  require_relative "rails/middleware"
  require_relative "rails/view_helper"

  module Imprint
    class Railtie < ::Rails::Railtie
      initializer "imprint.configure_rails_initialization" do |app|
        # Insert middleware AFTER ActionDispatch::Executor to avoid CurrentAttributes reset
        # The Executor resets ActiveSupport::CurrentAttributes, so we must run after it
        app.middleware.insert_after ActionDispatch::Executor, Imprint::Rails::Middleware
      end

      initializer "imprint.subscribe_to_notifications" do
        # Subscribe to ActiveSupport::Notifications after Rails initializes
        ActiveSupport.on_load(:active_record) do
          Imprint::Rails::Subscriber.subscribe_sql!
        end

        ActiveSupport.on_load(:action_controller) do
          Imprint::Rails::Subscriber.subscribe_controller!
        end

        ActiveSupport.on_load(:action_view) do
          include Imprint::ViewHelper
          Imprint::Rails::Subscriber.subscribe_view!
        end
      end

      # Configure ActiveJob trace context
      initializer "imprint.active_job" do
        ActiveSupport.on_load(:active_job) do
          require_relative "active_job"
          include Imprint::ActiveJob::TraceContext
        end
      end

      # Configure Delayed::Job if present
      initializer "imprint.delayed_job" do
        ActiveSupport.on_load(:delayed_job) do
          require_relative "delayed_job"
          Imprint::DelayedJob.configure!
        end

        # Fallback: configure if DJ is already loaded
        if defined?(::Delayed::Worker)
          require_relative "delayed_job"
          Imprint::DelayedJob.configure!
        end
      end

      # Configure Sidekiq if present
      initializer "imprint.sidekiq" do
        if defined?(::Sidekiq)
          require_relative "sidekiq"
          Imprint::Sidekiq.configure!
        end
      end

      # Configure default service name from Rails app
      config.after_initialize do
        if Imprint.configuration.service_name == "ruby-app" && defined?(::Rails.application)
          app_name = ::Rails.application.class.module_parent_name.underscore rescue nil
          Imprint.configuration.service_name = app_name if app_name
        end
      end

      # Shutdown client on application termination
      at_exit do
        Imprint.shutdown(timeout: 5)
      end
    end
  end
end
