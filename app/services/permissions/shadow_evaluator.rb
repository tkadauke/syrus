module Permissions
  class ShadowEvaluator
    SAFE_LOCAL_EFFECTS = %i[local_read isolated_workspace_write isolated_execution].freeze
    LOG_SOURCE = "permissions.shadow_evaluator".freeze

    Result = Data.define(:tool_name, :current_policy, :shadow_policy, :status, :safe_local, :decision, :error) do
      def mismatch? = status == :mismatch

      def to_h
        {
          tool_name: tool_name,
          current_policy: current_policy,
          shadow_policy: shadow_policy,
          status: status,
          safe_local: safe_local,
          decision: decision&.to_h,
          error: error
        }.compact
      end
    end

    class << self
      def compare(entries:, context:, current_entries:)
        current = current_entries.index_with(true)
        entries.map { |entry| new(entry:, context:, currently_allowed: current.include?(entry)).call }
      end
    end

    def initialize(entry:, context:, currently_allowed:, evaluator: PolicyEvaluator)
      @entry = entry
      @context = context
      @currently_allowed = currently_allowed
      @evaluator = evaluator
    end

    def call
      current_policy = @currently_allowed ? :allow : :deny
      decision = @evaluator.new(
        descriptor: @entry.descriptor,
        role: @context.role,
        resource_scope: {},
        context: evaluator_context,
        arguments: {}
      ).call
      status = current_policy == decision.policy ? :parity : :mismatch
      result = Result.new(tool_name: @entry.tool_name, current_policy:, shadow_policy: decision.policy,
        status:, safe_local: safe_local?, decision:, error: nil)
      record(result) if result.mismatch?
      result
    rescue StandardError => error
      # Shadow evaluation is observational. The legacy decision remains the
      # dispatch decision even when evaluator infrastructure is unavailable.
      result = Result.new(tool_name: @entry.tool_name,
        current_policy: @currently_allowed ? :allow : :deny,
        shadow_policy: nil, status: safe_local? ? :evaluation_failed_safe_local : :evaluation_failed,
        safe_local: safe_local?, decision: nil, error: "#{error.class}: #{error.message}")
      record(result)
      result
    end

    private

    def evaluator_context
      {
        surface: @context.surface.to_s,
        role: @context.role.to_s,
        user_id: @context.user&.id,
        repository_id: @context.repository&.id,
        job_id: @context.job&.id,
        workflow_id: @context.workflow&.id,
        run_id: @context.run&.id,
        chat_session_id: @context.chat_session&.id,
        agent_id: @context.agent_actor&.id
      }.compact
    end

    def safe_local?
      effects = @entry.descriptor.effects
      effects.present? && (effects - SAFE_LOCAL_EFFECTS).empty?
    end

    def record(result)
      OperationalLogging.ingest(
        level: result.mismatch? ? :info : :warn,
        source: LOG_SOURCE,
        message: result.mismatch? ? "Permission shadow decision differs from current dispatch" : "Permission shadow evaluation failed",
        context: result.to_h.except(:decision).merge(
          surface: @entry.surface,
          role: @context.role,
          capability: @entry.descriptor.capability,
          operation: result.decision&.invocation&.operation,
          effects: @entry.descriptor.effects,
          risk: @entry.descriptor.risk,
          user_id: @context.user&.id,
          chat_session_id: @context.chat_session&.id
        ).compact,
        role: "permission_shadow"
      )
    rescue StandardError => error
      Rails.logger.warn("[Permissions::ShadowEvaluator] diagnostic recording failed: #{error.class}: #{error.message}")
    end
  end
end
