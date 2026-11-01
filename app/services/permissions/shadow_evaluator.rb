module Permissions
  class ShadowEvaluator
    SAFE_LOCAL_EFFECTS = %i[local_read isolated_workspace_write isolated_execution].freeze
    LOG_SOURCE = "permissions.shadow_evaluator".freeze
    DIAGNOSTIC_DEDUPLICATION_WINDOW = 5.minutes

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

      def record_once(key)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        diagnostic_mutex.synchronize do
          diagnostic_seen.delete_if { |_seen_key, seen_at| now - seen_at >= DIAGNOSTIC_DEDUPLICATION_WINDOW }
          return false if diagnostic_seen.key?(key)

          diagnostic_seen[key] = now
        end
        yield
        true
      end

      def reset_diagnostic_throttle!
        diagnostic_mutex.synchronize { diagnostic_seen.clear }
      end

      private

      def diagnostic_mutex
        @diagnostic_mutex ||= Mutex.new
      end

      def diagnostic_seen
        @diagnostic_seen ||= {}
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
      safe_local = safe_local?
      result = Result.new(tool_name: @entry.tool_name,
        current_policy: @currently_allowed ? :allow : :deny,
        shadow_policy: nil, status: safe_local ? :evaluation_failed_safe_local : :evaluation_failed,
        safe_local:, decision: nil, error: "#{error.class}: #{error.message}")
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
      self.class.record_once(diagnostic_key(result)) do
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
      end
    rescue StandardError => error
      Rails.logger.warn("[Permissions::ShadowEvaluator] diagnostic recording failed: #{error.class}: #{error.message}")
    end

    def diagnostic_key(result)
      [ @entry.tool_name, @entry.surface, @context.role, result.current_policy,
        result.shadow_policy, result.status, result.safe_local ]
    end
  end
end
