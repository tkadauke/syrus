module ProviderRoutingRuleSerialization
  include AgentProviderCatalogOptions

  private

  def provider_routing_rules_json(scope_type:, scope_id:, **)
    ProviderRoutingRule
      .where(scope_type: scope_type, scope_id: scope_id)
      .order(:position, :id)
      .map { |rule| provider_routing_rule_json(rule) }
  end

  def provider_routing_scope_json(scope)
    {
      type: scope[:scope_type],
      id: scope[:scope_id],
      user_id: scope[:user_id],
      repository_id: scope[:repository_id],
      job_id: scope[:job_id]
    }.compact
  end

  def provider_routing_inherited_context_json(scope)
    inherited = []
    if scope[:scope_type] != "user" && scope[:user_id].present?
      inherited << provider_routing_scope_context_json("user", scope[:user_id], "User defaults")
    end
    if scope[:scope_type] == "job" && scope[:repository_id].present?
      inherited << provider_routing_scope_context_json("repository", scope[:repository_id], "Repository overrides")
    end
    inherited.compact
  end

  def provider_routing_scope_context_json(scope_type, scope_id, label)
    {
      scope_type: scope_type,
      scope_id: scope_id,
      label: label,
      rules: provider_routing_rules_json(scope_type: scope_type, scope_id: scope_id)
    }
  end

  def provider_routing_rule_json(rule)
    {
      id: rule.id,
      scope_type: rule.scope_type,
      scope_id: rule.scope_id,
      user_id: rule.user_id,
      repository_id: rule.repository_id,
      job_id: rule.job_id,
      position: rule.position,
      task_key: rule.task_key,
      trigger: rule.trigger,
      conditions: rule.conditions,
      action: rule.action,
      candidates: Array(rule.action_candidates).map { |candidate| provider_routing_candidate_json(candidate) },
      created_at: rule.created_at&.iso8601,
      updated_at: rule.updated_at&.iso8601
    }
  end

  def provider_routing_registry_options_json
    {
      triggers: {
        chat_roles: AgentRole::CHAT_ROLES.map do |role|
          provider_routing_option_json(role, role.delete_prefix("chat:").humanize)
        end,
        step_kinds: Step::Kind.entries.select(&:agentic).map { |entry| provider_routing_kind_entry_json(entry) }
      },
      conditions: {
        workflow_trigger_kinds: Workflow::TriggerKind.entries.map { |entry| provider_routing_kind_entry_json(entry) }
      },
      action_strategies: ProviderRoutingRule::ACTION_STRATEGIES.map do |strategy|
        provider_routing_option_json(strategy, strategy.humanize)
      end,
      condition_keys: ProviderRoutingRule::CONDITION_KEYS.map do |key|
        provider_routing_option_json(key, key.humanize)
      end
    }
  end

  def provider_routing_options_json(user = Current.user)
    agent_provider_catalog_options(user).merge(provider_routing_registry_options_json)
  end

  def provider_routing_kind_entry_json(entry)
    {
      value: entry.kind,
      label: entry.label,
      style: entry.respond_to?(:style) ? entry.style : nil
    }.compact
  end

  def provider_routing_option_json(value, label)
    {
      value: value,
      label: label
    }
  end

  def provider_routing_candidate_json(candidate)
    candidate = candidate.to_h.stringify_keys
    {
      provider: candidate["provider"].to_s,
      model: candidate["model"].presence,
      effort_level: candidate["effort_level"].presence
    }.compact
  end

  def provider_routing_rule_attrs
    attrs = params.require(:provider_routing_rule).permit(
      :task_key,
      :position,
      trigger: {},
      conditions: {},
      action: {},
      candidates: [ :provider, :model, :effort_level ]
    )

    task_key = attrs[:task_key].to_s.strip.presence || ProviderRoutingRule::DEFAULT_TASK_KEY
    candidates = provider_routing_candidates_from(attrs[:candidates])
    trigger = provider_routing_payload_hash(attrs[:trigger])
    action = provider_routing_payload_hash(attrs[:action])

    {
      position: attrs[:position],
      task_key: task_key,
      trigger: trigger || provider_routing_legacy_trigger_for(task_key),
      conditions: provider_routing_payload_hash(attrs[:conditions]),
      action: action || { strategy: "fallback_order", candidates: candidates },
      candidates: candidates
    }.compact
  end

  def provider_routing_reorder_ids
    Array(params[:provider_routing_rule_ids] || params[:ids]).filter_map do |id|
      Integer(id, exception: false)
    end
  end

  def provider_routing_legacy_trigger_for(task_key)
    return { type: "default" } if task_key == ProviderRoutingRule::DEFAULT_TASK_KEY

    { type: "legacy_task", task_key: task_key }
  end

  def provider_routing_payload_hash(value)
    return nil if value.blank?
    return value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    return value.to_h if value.respond_to?(:to_h)

    value
  end

  def provider_routing_candidates_from(candidates)
    Array(candidates).map do |candidate|
      next unless candidate.respond_to?(:to_h)

      candidate.to_h
        .slice("provider", "model", "effort_level")
        .transform_values { |value| value.to_s.strip.presence }
        .compact
    end.compact
  end
end
