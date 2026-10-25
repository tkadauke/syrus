class ProviderRoutingRule::Action::Route::Strategy::Panel < ProviderRoutingRule::Action::Route::Strategy
  CONSENSUS_VALUES = %w[unanimous majority].freeze
  UNAVAILABLE_POLICIES = %w[drop hold fail].freeze

  def panel? = true

  def validate(record)
    members = Array(attributes["candidates"])
    record.errors.add(:action, :panel_trigger_not_capable) unless record.send(:panel_capable_trigger?)
    record.errors.add(:action, :panel_requires_distinct_candidates) if members.size < 2 || member_keys(members).uniq.size != members.size
    validate_consensus(record, members.size)
    validate_integer(record, "min_members", 1..members.size)
    policy = attributes["on_unavailable"].to_s
    record.errors.add(:action, :panel_unknown_unavailable_policy) unless UNAVAILABLE_POLICIES.include?(policy)
  end

  private

  def member_keys(members)
    members.map { |member| member.to_h.stringify_keys.values_at("provider", "model", "effort_level") }
  end

  def validate_consensus(record, member_count)
    consensus = attributes["consensus"]
    return if CONSENSUS_VALUES.include?(consensus)

    threshold = consensus.to_h.stringify_keys["at_least"] if consensus.respond_to?(:to_h)
    record.errors.add(:action, :panel_invalid_consensus) unless threshold.is_a?(Integer) && threshold.between?(1, member_count)
  end

  def validate_integer(record, key, range)
    value = attributes[key]
    record.errors.add(:action, :panel_invalid_member_count, key: key) unless value.is_a?(Integer) && range.cover?(value)
  end
end
