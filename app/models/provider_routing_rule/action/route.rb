class ProviderRoutingRule::Action::Route < ProviderRoutingRule::Action
  def candidates
    Array(attributes["candidates"].presence || legacy_candidates)
  end

  def serialize
    super.merge("candidates" => candidates)
  end

  def validate(record)
    record.errors.add(:action, :candidates_must_be_array) unless attributes["candidates"].is_a?(Array)
    strategy_definition.validate(record)
  end

  def panel? = strategy_definition.panel?

  private

  def strategy_definition
    Strategy.for(attributes["strategy"], attributes)
  end
end
