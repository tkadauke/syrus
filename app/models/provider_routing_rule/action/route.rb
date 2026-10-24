class ProviderRoutingRule::Action::Route < ProviderRoutingRule::Action
  def candidates
    Array(attributes["candidates"].presence || legacy_candidates)
  end

  def serialize
    super.merge("candidates" => candidates)
  end

  def validate(record)
    strategy = attributes["strategy"].to_s
    record.errors.add(:action, :unknown_strategy, value: strategy.inspect) unless ProviderRoutingRule::ACTION_STRATEGIES.include?(strategy)
    record.errors.add(:action, :candidates_must_be_array) unless attributes["candidates"].is_a?(Array)
  end
end
