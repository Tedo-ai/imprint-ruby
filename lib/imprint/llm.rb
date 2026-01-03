# frozen_string_literal: true

module Imprint
  # LLM observability helpers for tracing LLM/AI model calls.
  #
  # Provides convenient methods for creating spans with LLM-specific attributes
  # following OpenTelemetry semantic conventions for GenAI.
  #
  # Example usage:
  #
  #   Imprint::LLM.span(provider: "openai", model: "gpt-4") do |span|
  #     response = openai_client.chat(messages: messages)
  #     span.set_attribute("llm.tokens_input", response.usage.prompt_tokens)
  #     span.set_attribute("llm.tokens_output", response.usage.completion_tokens)
  #     response
  #   end
  #
  #   # Or with all options upfront:
  #   Imprint::LLM.span(
  #     provider: "anthropic",
  #     model: "claude-3-opus",
  #     tokens_input: 150,
  #     tokens_output: 500,
  #     cost_usd: 0.023,
  #     prompt_template: "chat_completion",
  #     prompt_version: "v1.2"
  #   ) do |span|
  #     # LLM call here
  #   end
  #
  module LLM
    # LLM attribute keys following OpenTelemetry GenAI semantic conventions
    ATTR_SYSTEM = "llm.system"
    ATTR_MODEL = "llm.model"
    ATTR_TOKENS_INPUT = "llm.tokens_input"
    ATTR_TOKENS_OUTPUT = "llm.tokens_output"
    ATTR_COST_USD = "llm.cost_usd"
    ATTR_PROMPT_TEMPLATE = "llm.prompt_template"
    ATTR_PROMPT_VERSION = "llm.prompt_version"
    ATTR_FEEDBACK_CONFIDENCE = "llm.feedback_confidence"
    ATTR_FEEDBACK_SOURCE = "llm.feedback_source"
    ATTR_FEEDBACK_FLAGS = "llm.feedback_flags"

    class << self
      # Create a span for an LLM call with appropriate attributes.
      #
      # @param provider [String] The LLM provider/system (e.g., "openai", "anthropic", "cohere")
      # @param model [String] The model name (e.g., "gpt-4", "claude-3-opus", "command-r")
      # @param name [String, nil] Optional span name (defaults to "llm.{provider}.{model}")
      # @param tokens_input [Integer, nil] Number of input/prompt tokens
      # @param tokens_output [Integer, nil] Number of output/completion tokens
      # @param cost_usd [Float, nil] Cost of the call in USD
      # @param prompt_template [String, nil] Name/identifier of the prompt template used
      # @param prompt_version [String, nil] Version of the prompt template
      # @param feedback_confidence [Float, nil] Confidence score from feedback (0.0-1.0)
      # @param feedback_source [String, nil] Source of feedback (e.g., "user", "automated", "model")
      # @param feedback_flags [String, nil] Comma-separated feedback flags (e.g., "thumbs_up,helpful")
      # @param attributes [Hash] Additional custom attributes to set on the span
      # @yield [span] Block to execute within the span context
      # @return The result of the block
      #
      # @example Basic usage
      #   Imprint::LLM.span(provider: "openai", model: "gpt-4") do |span|
      #     response = client.chat(messages: messages)
      #     span.set_attribute("llm.tokens_input", response.usage.prompt_tokens)
      #     response
      #   end
      #
      # @example With all options
      #   Imprint::LLM.span(
      #     provider: "anthropic",
      #     model: "claude-3-opus",
      #     tokens_input: 150,
      #     tokens_output: 500,
      #     cost_usd: 0.023,
      #     prompt_template: "customer_support",
      #     prompt_version: "v2.1",
      #     feedback_confidence: 0.95,
      #     feedback_source: "user",
      #     feedback_flags: "helpful,accurate"
      #   ) do |span|
      #     # LLM call
      #   end
      #
      def span(
        provider:,
        model:,
        name: nil,
        tokens_input: nil,
        tokens_output: nil,
        cost_usd: nil,
        prompt_template: nil,
        prompt_version: nil,
        feedback_confidence: nil,
        feedback_source: nil,
        feedback_flags: nil,
        attributes: {},
        &block
      )
        span_name = name || "llm.#{provider}.#{model}"

        Imprint.start_span(span_name, kind: "client") do |s|
          # Set core LLM attributes
          s.set_attribute(ATTR_SYSTEM, provider.to_s)
          s.set_attribute(ATTR_MODEL, model.to_s)

          # Set optional token counts
          s.set_attribute(ATTR_TOKENS_INPUT, tokens_input.to_s) if tokens_input
          s.set_attribute(ATTR_TOKENS_OUTPUT, tokens_output.to_s) if tokens_output

          # Set cost if provided
          s.set_attribute(ATTR_COST_USD, cost_usd.to_s) if cost_usd

          # Set prompt template info
          s.set_attribute(ATTR_PROMPT_TEMPLATE, prompt_template.to_s) if prompt_template
          s.set_attribute(ATTR_PROMPT_VERSION, prompt_version.to_s) if prompt_version

          # Set feedback attributes
          s.set_attribute(ATTR_FEEDBACK_CONFIDENCE, feedback_confidence.to_s) if feedback_confidence
          s.set_attribute(ATTR_FEEDBACK_SOURCE, feedback_source.to_s) if feedback_source
          s.set_attribute(ATTR_FEEDBACK_FLAGS, feedback_flags.to_s) if feedback_flags

          # Set any additional custom attributes
          attributes.each { |k, v| s.set_attribute(k.to_s, v.to_s) }

          yield s
        end
      end

      # Record an LLM event (instant span with 0 duration).
      # Useful for logging LLM-related events without timing a call.
      #
      # @param provider [String] The LLM provider/system
      # @param model [String] The model name
      # @param event_name [String] Name of the event (e.g., "llm.cache_hit", "llm.rate_limited")
      # @param attributes [Hash] Additional attributes to set on the event
      #
      # @example
      #   Imprint::LLM.event("openai", "gpt-4", "llm.cache_hit", cache_key: "abc123")
      #
      def event(provider, model, event_name, attributes = {})
        event_attributes = {
          ATTR_SYSTEM => provider.to_s,
          ATTR_MODEL => model.to_s
        }.merge(attributes.transform_keys(&:to_s))

        Imprint.record_event(event_name, attributes: event_attributes)
      end

      # Helper to calculate estimated cost based on token counts and pricing.
      #
      # @param tokens_input [Integer] Number of input tokens
      # @param tokens_output [Integer] Number of output tokens
      # @param input_price_per_1k [Float] Price per 1000 input tokens in USD
      # @param output_price_per_1k [Float] Price per 1000 output tokens in USD
      # @return [Float] Estimated cost in USD
      #
      # @example OpenAI GPT-4 pricing
      #   cost = Imprint::LLM.estimate_cost(
      #     tokens_input: 1500,
      #     tokens_output: 500,
      #     input_price_per_1k: 0.03,
      #     output_price_per_1k: 0.06
      #   )
      #   # => 0.075
      #
      def estimate_cost(tokens_input:, tokens_output:, input_price_per_1k:, output_price_per_1k:)
        input_cost = (tokens_input.to_f / 1000) * input_price_per_1k
        output_cost = (tokens_output.to_f / 1000) * output_price_per_1k
        (input_cost + output_cost).round(6)
      end
    end
  end
end
