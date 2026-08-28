module Evals
  ScenarioResult = Struct.new(
    :scenario_slug, :scenario_name, :target, :provider,
    :passed, :rationale, :verifier_error,
    :history_intact, :agent_error, :cost_usd, :turns, :ran_at,
    keyword_init: true
  ) do
    def to_h
      super.transform_values { |v| v.is_a?(BigDecimal) ? v.to_f : v }
    end
  end
end
