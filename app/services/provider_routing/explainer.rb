module ProviderRouting
  class Explainer
    def self.call(job:, task_key:, trigger: nil, workflow_trigger_kind: nil)
      new(job: job, task_key: task_key, trigger: trigger, workflow_trigger_kind: workflow_trigger_kind).call
    end

    def initialize(job:, task_key:, trigger:, workflow_trigger_kind:)
      @job = job
      @task_key = task_key.to_s
      @trigger = trigger&.to_h&.deep_stringify_keys
      @workflow_trigger_kind = workflow_trigger_kind
    end

    def call
      resolution = Resolver.resolve(job: job, task_key: task_key, trigger: trigger, workflow_trigger_kind: workflow_trigger_kind)
      {
        job_id: job.id,
        invocation: invocation,
        scope_precedence: scope_trace(resolution),
        explicit_pin: explicit_pin,
        winning_decision: resolution.explanation,
        active_holds: active_holds
      }.compact
    end

    private

    attr_reader :job, :task_key, :trigger, :workflow_trigger_kind

    def invocation
      trigger.presence ||
        if Step::Kind.agentic_values.include?(task_key)
          { "type" => "step", "kind" => task_key }
        elsif AgentRole::CHAT_ROLES.include?(task_key)
          { "type" => "chat_role", "role" => task_key }
        else
          { "type" => "legacy_task", "task_key" => task_key, "kind" => task_key }
        end
    end

    def scope_trace(resolution)
      decision_reached = explicit_pin.present?
      scopes.map do |scope_type, scope_id|
        rules = ProviderRoutingRule.where(scope_type: scope_type, scope_id: scope_id).order(:position, :id)
        {
          scope_type: scope_type,
          scope_id: scope_id,
          rules: rules.map do |rule|
            trace = rule_trace(rule, resolution, decision_reached: decision_reached)
            decision_reached ||= trace[:outcome] == "matched_winner"
            trace
          end
        }
      end
    end

    def scopes
      [ [ "job", job.id ], [ "repository", job.repository_id ], [ "user", job.effective_owner_id ] ].select { |_type, id| id.present? }
    end

    def rule_trace(rule, resolution, decision_reached:)
      attempts = [ invocation, { "type" => "default" } ].uniq.map do |candidate_invocation|
        rule.match_details(invocation: candidate_invocation, job: job, workflow_trigger_kind: workflow_trigger_kind)
      end
      matched = attempts.any? { |attempt| attempt["matched"] }
      outcome = if explicit_pin.present?
        "overridden_by_explicit_pin"
      elsif decision_reached
        "not_evaluated_after_winner"
      elsif !rule.enabled?
        "disabled_skipped"
      elsif matched && resolution.matched_rule&.id == rule.id
        "matched_winner"
      else
        "match_failed"
      end
      {
        id: rule.id,
        position: rule.position,
        enabled: rule.enabled?,
        outcome: outcome,
        winning: resolution.matched_rule&.id == rule.id,
        trigger: rule.trigger,
        conditions: rule.conditions,
        action: rule.serialized_action,
        evidence: attempts
      }
    end

    def explicit_pin
      return if job.job_provider_setting_default?

      { overrides_rules: true, provider: job.workflow_agent_provider, model: job.model, effort_level: job.effort_level }.compact
    end

    def active_holds
      ProviderRoutingHold.active.joins(:workflow).where(workflows: { job_id: job.id }).map do |hold|
        {
          id: hold.id,
          workflow_id: hold.workflow_id,
          provider_routing_rule_id: hold.provider_routing_rule_id,
          reason: hold.reason,
          condition_evidence: hold.condition_evidence
        }
      end
    end
  end
end
