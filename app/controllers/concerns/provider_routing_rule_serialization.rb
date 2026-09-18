module ProviderRoutingRuleSerialization
  include AgentProviderCatalogOptions

  private

  def provider_routing_rules_json(scope_type:, scope_id:)
    ProviderRoutingRule
      .where(scope_type: scope_type, scope_id: scope_id)
      .order(:task_key, :id)
      .map { |rule| provider_routing_rule_json(rule) }
  end

  def provider_routing_rule_json(rule)
    {
      id: rule.id,
      scope_type: rule.scope_type,
      scope_id: rule.scope_id,
      task_key: rule.task_key,
      candidates: Array(rule.candidates).map { |candidate| provider_routing_candidate_json(candidate) },
      created_at: rule.created_at&.iso8601,
      updated_at: rule.updated_at&.iso8601
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
      candidates: [ :provider, :model, :effort_level ]
    )

    {
      task_key: attrs[:task_key].to_s.strip.presence || ProviderRoutingRule::DEFAULT_TASK_KEY,
      candidates: provider_routing_candidates_from(attrs[:candidates])
    }
  end

  def provider_routing_candidates_from(candidates)
    Array(candidates).map do |candidate|
      next unless candidate.respond_to?(:to_h)

      candidate.to_h.slice("provider", "model", "effort_level").transform_values { |value| value.to_s.strip.presence }.compact
    end.compact
  end
end
