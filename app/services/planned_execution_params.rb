class PlannedExecutionParams
  PARAM_KEYS = %w[
    planned_execution_project_label
    planned_execution_target_label
    planned_execution_capabilities
    planned_execution_source
  ].freeze

  def self.from_params(params)
    new(params).to_attributes
  end

  def initialize(params)
    @params = params.to_h.deep_stringify_keys
  end

  def to_attributes
    source = @params["planned_execution"].is_a?(Hash) ? @params["planned_execution"] : @params
    return {} unless PARAM_KEYS.any? { |key| source[key].present? } || source["capabilities"].present?

    requirement = PlannedExecutionRequirement.new(
      project_label: source["planned_execution_project_label"] || source["project_label"],
      target_label: source["planned_execution_target_label"] || source["target_label"],
      capabilities: source["planned_execution_capabilities"] || source["capabilities"],
      source: source["planned_execution_source"].presence || source["source"].presence || "operator"
    )
    {
      planned_execution_project_label: requirement.project_label,
      planned_execution_target_label: requirement.target_label,
      planned_execution_capabilities: requirement.capabilities,
      planned_execution_source: requirement.source
    }
  end
end
