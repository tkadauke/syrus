module Permissions
  # Records the canonical decision that actually governed an invocation. This
  # is diagnostic evidence only: logging failures never change authorization.
  class DecisionAudit
    LOG_SOURCE = "permissions.policy_evaluator".freeze

    def self.record(decision:, effective_policy: decision.policy, actor: nil, context: {}, fingerprint: nil)
      new(decision:, effective_policy:, actor:, context:, fingerprint:).record
    end

    def initialize(decision:, effective_policy:, actor:, context:, fingerprint:)
      @decision = decision
      @effective_policy = effective_policy
      @actor = actor
      @context = context.to_h.symbolize_keys
      @fingerprint = fingerprint
    end

    def record
      OperationalLogging.ingest(
        level: :info,
        source: LOG_SOURCE,
        message: "Canonical permission policy evaluated",
        context: diagnostic_context,
        role: "permission_policy"
      )
    rescue StandardError => error
      Rails.logger.warn("[Permissions::DecisionAudit] diagnostic recording failed: #{error.class}: #{error.message}")
      nil
    end

    private

    attr_reader :decision, :effective_policy, :actor, :context, :fingerprint

    def diagnostic_context
      {
        policy: decision.policy,
        effective_policy: effective_policy,
        capability: decision.invocation.capability,
        operation: decision.invocation.operation,
        effects: decision.invocation.effects,
        risk: decision.invocation.risk,
        invocation_fingerprint: fingerprint,
        decisive_layer: decision.decisive_rule&.layer,
        decisive_rule_id: decision.decisive_rule&.id,
        actor_type: actor&.class&.polymorphic_name,
        actor_id: actor&.id,
        role: context[:role],
        user_id: context[:user_id] || actor.try(:owner_user_id) || actor.try(:id),
        chat_session_id: context[:chat_session_id],
        job_id: context[:job_id],
        workflow_id: context[:workflow_id],
        run_id: context[:run_id]
      }.compact
    end
  end
end
