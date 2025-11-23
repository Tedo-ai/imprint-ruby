# frozen_string_literal: true

module Imprint
  # Context manages the current span for trace propagation.
  # Uses ActiveSupport::CurrentAttributes if available (Rails 5.2+),
  # otherwise falls back to Thread.current for thread-local storage.
  module Context
    class << self
      # Get the current span
      def current_span
        if current_class
          current_class.span
        else
          Thread.current[:imprint_current_span]
        end
      end

      # Set the current span
      def current_span=(span)
        if current_class
          current_class.span = span
        else
          Thread.current[:imprint_current_span] = span
        end
      end

      # Get the current trace ID
      def current_trace_id
        current_span&.trace_id
      end

      # Get the current span ID
      def current_span_id
        current_span&.span_id
      end

      # Execute a block with a span as the current context
      def with_span(span)
        previous_span = current_span
        self.current_span = span
        yield
      ensure
        self.current_span = previous_span
      end

      # Clear the current context (useful at request boundaries)
      def clear!
        if current_class
          current_class.reset
        else
          Thread.current[:imprint_current_span] = nil
        end
      end

      private

      # Lazily define and return the Current class if ActiveSupport is available
      def current_class
        return @current_class if defined?(@current_class)

        @current_class = if defined?(ActiveSupport::CurrentAttributes)
          # Define the Current class dynamically
          unless defined?(Imprint::Current)
            Imprint.const_set(:Current, Class.new(ActiveSupport::CurrentAttributes) do
              attribute :span
            end)
          end
          Imprint::Current
        else
          nil
        end
      end
    end
  end
end
