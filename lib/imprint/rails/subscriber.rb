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

          %w[
            render_template.action_view
            render_partial.action_view
            render_collection.action_view
          ].each do |event_name|
            ActiveSupport::Notifications.subscribe(event_name) do |*args|
              handle_view_event(args)
            end
          end

          @view_subscribed = true
        end

        def subscribe_cache!
          return if @cache_subscribed

          %w[
            cache_read.active_support
            cache_write.active_support
            cache_fetch_hit.active_support
            cache_generate.active_support
          ].each do |event_name|
            ActiveSupport::Notifications.subscribe(event_name) do |*args|
              handle_cache_event(args)
            end
          end

          @cache_subscribed = true
        end

        def subscribe_mailer!
          return if @mailer_subscribed

          %w[
            process.action_mailer
            deliver.action_mailer
          ].each do |event_name|
            ActiveSupport::Notifications.subscribe(event_name) do |*args|
              handle_mailer_event(args)
            end
          end

          @mailer_subscribed = true
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

          record_event_exception(span, event.payload[:exception])

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
          parent.set_attribute("process.ruby.objects.allocated", event.payload[:allocations]) if event.payload[:allocations]

          record_event_exception(parent, event.payload[:exception])
        end

        def handle_view_event(args)
          return unless Imprint.client.enabled?

          event = ActiveSupport::Notifications::Event.new(*args)
          parent = Context.current_span
          return unless parent

          span = create_child_span(
            parent: parent,
            name: view_span_name(event),
            kind: "internal",
            duration_ms: event.duration
          )

          identifier = event.payload[:identifier]
          span.set_attribute("template.identifier", identifier) if identifier
          span.set_attribute("template.layout", event.payload[:layout]) if event.payload[:layout]
          span.set_attribute("template.virtual_path", event.payload[:virtual_path]) if event.payload[:virtual_path]
          span.set_attribute("template.count", event.payload[:count]) if event.payload[:count]
          span.set_attribute("template.cache_hit", event.payload[:cache_hit]) unless event.payload[:cache_hit].nil?

          Imprint.client.queue_span(span)
        end

        def handle_cache_event(args)
          return unless Imprint.client.enabled?

          event = ActiveSupport::Notifications::Event.new(*args)
          parent = Context.current_span
          return unless parent

          span = create_child_span(
            parent: parent,
            name: cache_span_name(event.name),
            kind: "client",
            duration_ms: event.duration
          )

          key_prefix = cache_key_prefix(event.payload[:key])
          span.set_attribute("cache.key_prefix", key_prefix) if key_prefix
          span.set_attribute("cache.operation", cache_operation(event.name))

          cache_hit = cache_hit_value(event.name, event.payload)
          span.set_attribute("cache.hit", cache_hit) unless cache_hit.nil?
          span.set_attribute("cache.store", event.payload[:store]) if event.payload[:store]
          span.set_attribute("cache.super_operation", event.payload[:super_operation]) if event.payload[:super_operation]

          record_event_exception(span, event.payload[:exception])

          Imprint.client.queue_span(span)
        end

        def handle_mailer_event(args)
          return unless Imprint.client.enabled?

          event = ActiveSupport::Notifications::Event.new(*args)
          parent = Context.current_span
          return unless parent

          span = create_child_span(
            parent: parent,
            name: mailer_span_name(event),
            kind: "internal",
            duration_ms: event.duration
          )

          span.set_attribute("mailer.class", event.payload[:mailer]) if event.payload[:mailer]
          span.set_attribute("mailer.action", event.payload[:action]) if event.payload[:action]
          span.set_attribute("email.message_id", event.payload[:message_id]) if event.payload[:message_id]
          span.set_attribute("email.subject", truncate_text(event.payload[:subject], max_length: 255)) if event.payload[:subject]
          span.set_attribute("mailer.perform_deliveries", event.payload[:perform_deliveries]) unless event.payload[:perform_deliveries].nil?
          span.set_attribute("mailer.to_count", Array(event.payload[:to]).compact.length) if event.payload[:to]

          record_event_exception(span, event.payload[:exception])

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

        def truncate_text(text, max_length:)
          value = text.to_s
          value.length > max_length ? "#{value[0, max_length]}..." : value
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

        def view_span_name(event)
          label = view_label(event.payload)

          case event.name
          when "render_partial.action_view"
            "render partial #{label}"
          when "render_collection.action_view"
            "render collection #{label}"
          else
            "render #{label}"
          end
        end

        def view_label(payload)
          payload[:virtual_path] || payload[:identifier]&.yield_self { |value| File.basename(value) } || "template"
        end

        def cache_span_name(event_name)
          case event_name
          when "cache_fetch_hit.active_support"
            "cache.fetch"
          when "cache_generate.active_support"
            "cache_miss_compute"
          when "cache_write.active_support"
            "cache.write"
          else
            "cache.read"
          end
        end

        def cache_operation(event_name)
          event_name.split(".").first.sub("cache_", "")
        end

        def cache_hit_value(event_name, payload)
          return true if event_name == "cache_fetch_hit.active_support"
          return false if event_name == "cache_generate.active_support"
          return payload[:hit] unless payload[:hit].nil?

          nil
        end

        def cache_key_prefix(key)
          return nil if key.nil?

          raw_key = Array(key).join("/")
          delimiter = raw_key.include?("/") ? "/" : ":"
          segments = raw_key.split(delimiter).reject(&:empty?).first(3)
          segments = [raw_key] if segments.empty?

          segments
            .map { |segment| sanitize_cache_segment(segment) }
            .join(delimiter)
        end

        def sanitize_cache_segment(segment)
          segment
            .to_s
            .gsub(/\b[0-9a-f]{8,}\b/i, "*")
            .gsub(/\b\d+\b/, "*")
            .slice(0, 64)
        end

        def mailer_span_name(event)
          if event.name == "deliver.action_mailer"
            "mailer.deliver"
          else
            "mailer.process"
          end
        end

        def record_event_exception(span, exception_payload)
          return unless exception_payload

          if exception_payload.is_a?(Array)
            span.record_error(exception_payload.join(": "))
          else
            span.record_error(exception_payload)
          end
        end
      end
    end
  end
end
