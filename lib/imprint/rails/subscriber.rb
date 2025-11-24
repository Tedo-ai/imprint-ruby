# frozen_string_literal: true

module Imprint
  module Rails
    # Subscribes to ActiveSupport::Notifications for automatic instrumentation
    module Subscriber
      class << self
        def subscribe_sql!
          return if @sql_subscribed

          ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
            handle_sql_event(args)
          end
          @sql_subscribed = true
        end

        def subscribe_controller!
          return if @controller_subscribed

          ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
            handle_controller_event(args)
          end
          @controller_subscribed = true
        end

        def subscribe_view!
          return if @view_subscribed

          ActiveSupport::Notifications.subscribe("render_template.action_view") do |*args|
            handle_view_event(args)
          end
          @view_subscribed = true
        end

        private

        def handle_sql_event(args)
          return unless Imprint.client.enabled?

          event = ActiveSupport::Notifications::Event.new(*args)
          parent = Context.current_span
          return unless parent

          # Skip schema queries and EXPLAIN
          return if event.payload[:name] == "SCHEMA" || event.payload[:sql]&.start_with?("EXPLAIN")

          span = create_child_span(
            parent: parent,
            name: event.payload[:name] || "SQL",
            kind: "client",
            duration_ms: event.duration
          )

          sql = event.payload[:sql]
          span.set_attribute("db.system", adapter_name)
          span.set_attribute("db.statement", truncate_sql(sql)) if sql
          span.set_attribute("db.name", database_name)

          if event.payload[:exception]
            span.record_error(event.payload[:exception].join(": "))
          end

          Imprint.client.queue_span(span)
        end

        def handle_controller_event(args)
          return unless Imprint.client.enabled?

          event = ActiveSupport::Notifications::Event.new(*args)
          parent = Context.current_span
          return unless parent

          # Update span name to use Rails route pattern instead of actual path
          # This provides consistency with other agents (Go/JS) that use route patterns
          http_method = event.payload[:method]
          route_pattern = extract_route_pattern(event.payload)

          if route_pattern
            parent.set_name("#{http_method} #{route_pattern}")
          else
            # Fallback to method + path if route pattern unavailable
            path = event.payload[:path] || parent.name.split(" ", 2)[1]
            parent.set_name("#{http_method} #{path}")
          end

          # Add controller-specific attributes to the parent span
          parent.set_attribute("code.namespace", event.payload[:controller])
          parent.set_attribute("code.function", event.payload[:action])
          parent.set_attribute("controller", event.payload[:controller])
          parent.set_attribute("action", event.payload[:action])
          parent.set_attribute("format", event.payload[:format])
          parent.set_attribute("db_runtime", event.payload[:db_runtime]&.round(2))
          parent.set_attribute("view_runtime", event.payload[:view_runtime]&.round(2))

          if event.payload[:exception]
            parent.record_error(event.payload[:exception].join(": "))
          end
        end

        def handle_view_event(args)
          return unless Imprint.client.enabled?

          event = ActiveSupport::Notifications::Event.new(*args)
          parent = Context.current_span
          return unless parent

          identifier = event.payload[:identifier]
          template_name = identifier ? File.basename(identifier) : "template"

          span = create_child_span(
            parent: parent,
            name: "render #{template_name}",
            kind: "internal",
            duration_ms: event.duration
          )

          span.set_attribute("template.identifier", identifier) if identifier
          span.set_attribute("template.layout", event.payload[:layout]) if event.payload[:layout]

          Imprint.client.queue_span(span)
        end

        def create_child_span(parent:, name:, kind:, duration_ms:)
          span = Span.new(
            trace_id: parent.trace_id,
            span_id: Span.generate_span_id,
            parent_id: parent.span_id,
            namespace: Imprint.configuration.service_name,
            name: name,
            kind: kind,
            client: nil # Don't auto-queue on finish
          )

          # Manually set the duration since we already have it
          span.instance_variable_set(:@duration_ns, (duration_ms * 1_000_000).to_i)
          span.instance_variable_set(:@ended, true)
          span
        end

        def adapter_name
          @adapter_name ||= if defined?(ActiveRecord::Base)
            ActiveRecord::Base.connection.adapter_name.downcase
          else
            "unknown"
          end
        rescue
          "unknown"
        end

        def database_name
          @database_name ||= if defined?(ActiveRecord::Base)
            ActiveRecord::Base.connection_db_config.database
          else
            "unknown"
          end
        rescue
          "unknown"
        end

        def truncate_sql(sql, max_length: 2048)
          return nil unless sql

          sql.length > max_length ? "#{sql[0, max_length]}..." : sql
        end

        def extract_route_pattern(payload)
          # Try to get the route pattern from Rails routing
          # The route pattern provides parameterized paths like /products/:id
          # instead of actual paths like /products/123
          return nil unless defined?(::Rails) && ::Rails.application

          controller = payload[:controller]
          action = payload[:action]
          return nil unless controller && action

          # Find the route that matches this controller#action
          routes = ::Rails.application.routes.routes
          route = routes.find do |r|
            r.defaults[:controller] == controller && r.defaults[:action] == action
          end

          # Extract the path pattern from the route
          if route && route.path.respond_to?(:spec)
            # Remove the format specification (.:format) and convert to string
            route.path.spec.to_s.gsub(/\(\.:format\)$/, "")
          end
        rescue => e
          # Fallback to nil if route extraction fails
          nil
        end
      end
    end
  end
end
