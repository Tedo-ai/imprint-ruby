# frozen_string_literal: true

module Imprint
  # Agent observability helpers for tracing AI agent workflows.
  #
  # Provides convenient methods for creating spans with agent-specific attributes
  # following the Agent Trace Standard semantic conventions.
  #
  # Agent sessions group related LLM calls, tool executions, human interactions,
  # and agent handoffs into a coherent workflow trace.
  #
  # Example usage:
  #
  #   Imprint::Agent.session(
  #     name: "travel-assistant",
  #     goal: "Book flight to Amsterdam",
  #     framework: "custom"
  #   ) do |session|
  #
  #     # LLM step
  #     session.llm_step("planning") do |step|
  #       step.reasoning = "Understanding user requirements"
  #       response = call_claude(planning_prompt)
  #       step.set_llm_response(response)
  #     end
  #
  #     # Tool step
  #     session.tool_step("search_flights", input: search_params) do |step|
  #       results = search_flights(search_params)
  #       step.output = results
  #     end
  #
  #     # Human approval
  #     session.human_step("approval") do |step|
  #       approved = wait_for_user_approval
  #       step.action = approved ? "approved" : "rejected"
  #     end
  #   end
  #
  module Agent
    # Session attribute keys
    ATTR_SESSION_ID = "agent.session.id"
    ATTR_SESSION_GOAL = "agent.session.goal"
    ATTR_SESSION_STATUS = "agent.session.status"
    ATTR_SESSION_TRIGGER = "agent.session.trigger"

    # Agent identity attributes
    ATTR_AGENT_NAME = "agent.name"
    ATTR_AGENT_VERSION = "agent.version"
    ATTR_AGENT_FRAMEWORK = "agent.framework"
    ATTR_AGENT_DESCRIPTION = "agent.description"

    # Step attributes
    ATTR_STEP_INDEX = "agent.step.index"
    ATTR_STEP_TYPE = "agent.step.type"
    ATTR_STEP_NAME = "agent.step.name"
    ATTR_STEP_REASONING = "agent.step.reasoning"
    ATTR_STEP_STATUS = "agent.step.status"

    # Tool attributes
    ATTR_TOOL_NAME = "agent.tool.name"
    ATTR_TOOL_DESCRIPTION = "agent.tool.description"
    ATTR_TOOL_INPUT = "agent.tool.input"
    ATTR_TOOL_OUTPUT = "agent.tool.output"
    ATTR_TOOL_STATUS = "agent.tool.status"
    ATTR_TOOL_ERROR = "agent.tool.error"
    ATTR_TOOL_RETRIES = "agent.tool.retries"

    # Human-in-the-loop attributes
    ATTR_HUMAN_ACTION = "agent.human.action"
    ATTR_HUMAN_FEEDBACK = "agent.human.feedback"
    ATTR_HUMAN_WAIT_MS = "agent.human.wait_ms"
    ATTR_HUMAN_USER_ID = "agent.human.user_id"

    # Handoff attributes
    ATTR_HANDOFF_TO = "agent.handoff.to"
    ATTR_HANDOFF_REASON = "agent.handoff.reason"
    ATTR_HANDOFF_CONTEXT = "agent.handoff.context"
    ATTR_HANDOFF_SESSION_ID = "agent.handoff.session_id"

    # Rollup attributes (set on session span)
    ATTR_TOTAL_COST_USD = "agent.session.total_cost_usd"
    ATTR_TOTAL_TOKENS_IN = "agent.session.total_tokens_in"
    ATTR_TOTAL_TOKENS_OUT = "agent.session.total_tokens_out"
    ATTR_LLM_CALLS = "agent.session.llm_calls"
    ATTR_TOOL_CALLS = "agent.session.tool_calls"
    ATTR_HUMAN_INTERACTIONS = "agent.session.human_interactions"

    # Valid session statuses
    SESSION_STATUSES = %w[running completed failed waiting_human].freeze

    # Valid step types
    STEP_TYPES = %w[llm tool human handoff reasoning].freeze

    # Valid step statuses
    STEP_STATUSES = %w[success failed skipped retried].freeze

    # Valid tool statuses
    TOOL_STATUSES = %w[success error timeout].freeze

    # Valid human actions
    HUMAN_ACTIONS = %w[approved rejected modified timeout].freeze

    class << self
      # Create an agent session span that groups all agent activity.
      #
      # @param name [String] Name of the agent (e.g., "travel-assistant")
      # @param goal [String] Human-readable goal/task for this session
      # @param framework [String] Framework used (e.g., "langchain", "autogen", "crewai", "custom")
      # @param version [String, nil] Optional agent version
      # @param description [String, nil] Optional description of what the agent does
      # @param trigger [String] What initiated the session ("user_message", "scheduled", "webhook", "agent_handoff")
      # @param session_id [String, nil] Optional custom session ID (auto-generated if not provided)
      # @param attributes [Hash] Additional custom attributes
      # @yield [session] Block to execute within the session context
      # @return The result of the block
      #
      def session(
        name:,
        goal:,
        framework: "custom",
        version: nil,
        description: nil,
        trigger: "user_message",
        session_id: nil,
        attributes: {},
        &block
      )
        session_obj = AgentSession.new(
          name: name,
          goal: goal,
          framework: framework,
          version: version,
          description: description,
          trigger: trigger,
          session_id: session_id,
          attributes: attributes
        )

        session_obj.run(&block)
      end
    end

    # Represents an agent session with step tracking.
    class AgentSession
      attr_reader :session_id, :name, :goal, :framework, :step_index
      attr_accessor :status

      def initialize(
        name:,
        goal:,
        framework:,
        version: nil,
        description: nil,
        trigger: "user_message",
        session_id: nil,
        attributes: {}
      )
        @name = name
        @goal = goal
        @framework = framework
        @version = version
        @description = description
        @trigger = trigger
        @session_id = session_id || generate_session_id
        @attributes = attributes
        @step_index = 0
        @status = "running"

        # Rollup counters
        @total_cost_usd = 0.0
        @total_tokens_in = 0
        @total_tokens_out = 0
        @llm_calls = 0
        @tool_calls = 0
        @human_interactions = 0

        @session_span = nil
        @mutex = Mutex.new
      end

      # Run the session block and manage the session span lifecycle.
      def run
        Imprint.start_span("agent.session", kind: "server") do |span|
          @session_span = span

          # Set session attributes
          span.set_attribute(ATTR_SESSION_ID, @session_id)
          span.set_attribute(ATTR_SESSION_GOAL, @goal)
          span.set_attribute(ATTR_SESSION_STATUS, @status)
          span.set_attribute(ATTR_SESSION_TRIGGER, @trigger)

          # Set agent identity
          span.set_attribute(ATTR_AGENT_NAME, @name)
          span.set_attribute(ATTR_AGENT_FRAMEWORK, @framework)
          span.set_attribute(ATTR_AGENT_VERSION, @version) if @version
          span.set_attribute(ATTR_AGENT_DESCRIPTION, @description) if @description

          # Set custom attributes
          @attributes.each { |k, v| span.set_attribute(k.to_s, v.to_s) }

          begin
            result = yield self
            @status = "completed"
            result
          rescue => e
            @status = "failed"
            span.record_error(e)
            raise
          ensure
            # Update final status and rollup counters
            span.set_attribute(ATTR_SESSION_STATUS, @status)
            span.set_attribute(ATTR_TOTAL_COST_USD, @total_cost_usd.to_s)
            span.set_attribute(ATTR_TOTAL_TOKENS_IN, @total_tokens_in.to_s)
            span.set_attribute(ATTR_TOTAL_TOKENS_OUT, @total_tokens_out.to_s)
            span.set_attribute(ATTR_LLM_CALLS, @llm_calls.to_s)
            span.set_attribute(ATTR_TOOL_CALLS, @tool_calls.to_s)
            span.set_attribute(ATTR_HUMAN_INTERACTIONS, @human_interactions.to_s)
          end
        end
      end

      # Create an LLM step within the session.
      #
      # @param step_name [String] Human-readable name for this step (e.g., "planning", "analysis")
      # @yield [step] Block that receives an AgentStep to configure
      # @return The result of the block
      #
      def llm_step(step_name, &block)
        execute_step("llm", step_name) do |step|
          result = yield step
          @mutex.synchronize do
            @llm_calls += 1
            @total_tokens_in += step.tokens_in
            @total_tokens_out += step.tokens_out
            @total_cost_usd += step.cost_usd
          end
          result
        end
      end

      # Create a tool execution step within the session.
      #
      # @param step_name [String] Human-readable name for this step
      # @param input [Object] Input data for the tool (will be JSON-encoded)
      # @param description [String, nil] Optional description of what the tool does
      # @yield [step] Block that receives an AgentStep to configure
      # @return The result of the block
      #
      def tool_step(step_name, input: nil, description: nil, &block)
        execute_step("tool", step_name) do |step|
          step.tool_input = input
          step.tool_description = description
          result = yield step
          @mutex.synchronize { @tool_calls += 1 }
          result
        end
      end

      # Create a human-in-the-loop step within the session.
      #
      # @param step_name [String] Human-readable name for this step (e.g., "approval", "feedback")
      # @param user_id [String, nil] Optional identifier of the human user
      # @yield [step] Block that receives an AgentStep to configure
      # @return The result of the block
      #
      def human_step(step_name, user_id: nil, &block)
        @status = "waiting_human"
        @session_span&.set_attribute(ATTR_SESSION_STATUS, @status)

        execute_step("human", step_name) do |step|
          step.human_user_id = user_id
          start_wait = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          result = yield step

          # Calculate wait time
          wait_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_wait) * 1000).to_i
          step.human_wait_ms = wait_ms

          @mutex.synchronize { @human_interactions += 1 }
          @status = "running"
          @session_span&.set_attribute(ATTR_SESSION_STATUS, @status)

          result
        end
      end

      # Create a handoff to another agent.
      #
      # @param to [String] Name of the target agent
      # @param reason [String] Why the handoff is happening
      # @param context [Object, nil] Context to pass to the target agent (will be JSON-encoded)
      # @return [String] The new session ID for the handoff
      #
      def handoff(to:, reason:, context: nil)
        new_session_id = generate_session_id

        execute_step("handoff", "handoff_to_#{to}") do |step|
          step.handoff_to = to
          step.handoff_reason = reason
          step.handoff_context = context
          step.handoff_session_id = new_session_id
        end

        new_session_id
      end

      private

      def execute_step(step_type, step_name)
        @mutex.synchronize { @step_index += 1 }
        current_index = @step_index

        span_name = "agent.#{@name}.#{step_type}.#{step_name}"

        Imprint.start_span(span_name, kind: "client") do |span|
          step = AgentStep.new(
            span: span,
            step_type: step_type,
            step_name: step_name,
            step_index: current_index,
            agent_name: @name
          )

          begin
            result = yield step
            step.finalize
            result
          rescue => e
            step.error = e
            step.status = "failed"
            step.finalize
            raise
          end
        end
      end

      def generate_session_id
        "sess_#{SecureRandom.hex(12)}"
      end
    end

    # Represents a single step within an agent session.
    # Yielded to step blocks to allow setting step-specific attributes.
    class AgentStep
      attr_accessor :reasoning, :status
      attr_accessor :tool_input, :tool_description, :tool_retries
      attr_accessor :human_action, :human_feedback, :human_wait_ms, :human_user_id
      attr_accessor :handoff_to, :handoff_reason, :handoff_context, :handoff_session_id
      attr_reader :tokens_in, :tokens_out, :cost_usd

      def initialize(span:, step_type:, step_name:, step_index:, agent_name:)
        @span = span
        @step_type = step_type
        @step_name = step_name
        @step_index = step_index
        @agent_name = agent_name

        @reasoning = nil
        @status = "success"
        @output = nil
        @error = nil

        # LLM-specific
        @tokens_in = 0
        @tokens_out = 0
        @cost_usd = 0.0
        @llm_provider = nil
        @llm_model = nil

        # Tool-specific
        @tool_input = nil
        @tool_output = nil
        @tool_description = nil
        @tool_retries = 0

        # Human-specific
        @human_action = nil
        @human_feedback = nil
        @human_wait_ms = nil
        @human_user_id = nil

        # Handoff-specific
        @handoff_to = nil
        @handoff_reason = nil
        @handoff_context = nil
        @handoff_session_id = nil

        # Set base step attributes
        @span.set_attribute(ATTR_STEP_INDEX, @step_index.to_s)
        @span.set_attribute(ATTR_STEP_TYPE, @step_type)
        @span.set_attribute(ATTR_STEP_NAME, @step_name)
      end

      # Set the output of the step.
      def output=(value)
        @output = value
        if @step_type == "tool"
          @tool_output = value
        end
      end

      # Get the output.
      def output
        @output
      end

      # Record an error on the step.
      def error=(value)
        @error = value
        @span.record_error(value) if value
      end

      # Set action for human steps.
      def action=(value)
        @human_action = value
      end

      # Get action for human steps.
      def action
        @human_action
      end

      # Set LLM response details from a response object or hash.
      # Automatically extracts tokens and cost if available.
      #
      # @param response [Object] Response from LLM call. Supports:
      #   - Hash with :tokens_in, :tokens_out, :cost_usd, :provider, :model keys
      #   - Object responding to usage.prompt_tokens, usage.completion_tokens
      #   - Any object (will just mark the step as having an LLM response)
      #
      def set_llm_response(response)
        case response
        when Hash
          @tokens_in = response[:tokens_in] || response["tokens_in"] || 0
          @tokens_out = response[:tokens_out] || response["tokens_out"] || 0
          @cost_usd = response[:cost_usd] || response["cost_usd"] || 0.0
          @llm_provider = response[:provider] || response["provider"]
          @llm_model = response[:model] || response["model"]
        else
          # Try to extract from object with usage attribute (OpenAI-style)
          if response.respond_to?(:usage)
            usage = response.usage
            if usage.respond_to?(:prompt_tokens)
              @tokens_in = usage.prompt_tokens || 0
            end
            if usage.respond_to?(:completion_tokens)
              @tokens_out = usage.completion_tokens || 0
            end
          end

          # Try to extract model info
          if response.respond_to?(:model)
            @llm_model = response.model
          end
        end
      end

      # Set token counts directly.
      def set_tokens(input:, output:)
        @tokens_in = input.to_i
        @tokens_out = output.to_i
      end

      # Set cost directly.
      def set_cost(usd:)
        @cost_usd = usd.to_f
      end

      # Set LLM provider and model directly.
      def set_llm_info(provider:, model:)
        @llm_provider = provider
        @llm_model = model
      end

      # Finalize the step by writing all attributes to the span.
      # Called automatically at the end of the step block.
      def finalize
        @span.set_attribute(ATTR_STEP_STATUS, @status)
        @span.set_attribute(ATTR_STEP_REASONING, @reasoning) if @reasoning

        case @step_type
        when "llm"
          finalize_llm_step
        when "tool"
          finalize_tool_step
        when "human"
          finalize_human_step
        when "handoff"
          finalize_handoff_step
        end
      end

      private

      def finalize_llm_step
        # Set LLM-specific attributes using the LLM module constants
        @span.set_attribute(LLM::ATTR_SYSTEM, @llm_provider.to_s) if @llm_provider
        @span.set_attribute(LLM::ATTR_MODEL, @llm_model.to_s) if @llm_model
        @span.set_attribute(LLM::ATTR_TOKENS_INPUT, @tokens_in.to_s) if @tokens_in > 0
        @span.set_attribute(LLM::ATTR_TOKENS_OUTPUT, @tokens_out.to_s) if @tokens_out > 0
        @span.set_attribute(LLM::ATTR_COST_USD, @cost_usd.to_s) if @cost_usd > 0
      end

      def finalize_tool_step
        @span.set_attribute(ATTR_TOOL_NAME, @step_name)
        @span.set_attribute(ATTR_TOOL_DESCRIPTION, @tool_description) if @tool_description
        @span.set_attribute(ATTR_TOOL_INPUT, encode_json(@tool_input)) if @tool_input
        @span.set_attribute(ATTR_TOOL_OUTPUT, encode_json(@tool_output)) if @tool_output
        @span.set_attribute(ATTR_TOOL_STATUS, @status == "success" ? "success" : "error")
        @span.set_attribute(ATTR_TOOL_ERROR, @error.to_s) if @error
        @span.set_attribute(ATTR_TOOL_RETRIES, @tool_retries.to_s) if @tool_retries > 0
      end

      def finalize_human_step
        @span.set_attribute(ATTR_HUMAN_ACTION, @human_action) if @human_action
        @span.set_attribute(ATTR_HUMAN_FEEDBACK, @human_feedback) if @human_feedback
        @span.set_attribute(ATTR_HUMAN_WAIT_MS, @human_wait_ms.to_s) if @human_wait_ms
        @span.set_attribute(ATTR_HUMAN_USER_ID, @human_user_id) if @human_user_id
      end

      def finalize_handoff_step
        @span.set_attribute(ATTR_HANDOFF_TO, @handoff_to) if @handoff_to
        @span.set_attribute(ATTR_HANDOFF_REASON, @handoff_reason) if @handoff_reason
        @span.set_attribute(ATTR_HANDOFF_CONTEXT, encode_json(@handoff_context)) if @handoff_context
        @span.set_attribute(ATTR_HANDOFF_SESSION_ID, @handoff_session_id) if @handoff_session_id
      end

      def encode_json(value)
        return value if value.is_a?(String)
        return value.to_json if value.respond_to?(:to_json)
        value.to_s
      rescue
        value.to_s
      end
    end
  end
end
