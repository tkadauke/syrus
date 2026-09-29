class PlannedExecutionRequirement
  SOURCES = %w[defaulted inferred explicit].freeze
  DEFAULT_CAPABILITIES = { "os" => [ "linux" ] }.freeze

  attr_reader :project_label, :target_label, :capabilities, :source

  def self.default
    new(capabilities: DEFAULT_CAPABILITIES, source: "defaulted")
  end

  def self.from_record(record)
    new(
      project_label: record.planned_execution_project_label,
      target_label: record.planned_execution_target_label,
      capabilities: record.planned_execution_capabilities,
      source: record.planned_execution_source
    )
  end

  def self.from_attributes(attributes)
    return default if attributes.blank?

    new(**attributes.symbolize_keys.slice(:project_label, :target_label, :capabilities, :source))
  end

  def self.for_workflow(job:, override: nil)
    return from_attributes(override) if override.present?

    from_record(job)
  end

  def initialize(project_label: nil, target_label: nil, capabilities: nil, source: nil)
    @project_label = project_label.to_s.strip.presence
    @target_label = target_label.to_s.strip.presence
    @capabilities = normalize_capabilities(capabilities)
    @source = normalize_source(source)
  end

  def assign_to(record)
    record.planned_execution_project_label = project_label
    record.planned_execution_target_label = target_label
    record.planned_execution_capabilities = capabilities
    record.planned_execution_source = source
  end

  def to_h
    {
      "project_label" => project_label,
      "target_label" => target_label,
      "capabilities" => capabilities,
      "source" => source
    }
  end

  def as_json(*)
    to_h
  end

  private

  def normalize_source(value)
    normalized = value.to_s.strip.presence || "defaulted"
    return normalized if SOURCES.include?(normalized)

    raise ArgumentError, "planned execution source #{normalized.inspect} must be one of #{SOURCES.join(', ')}"
  end

  def normalize_capabilities(value)
    return value.to_h if value.is_a?(TargetGraph::ExecutionCapabilities)

    raw = value.presence || DEFAULT_CAPABILITIES
    TargetGraph::ExecutionCapabilities.new(**raw.symbolize_keys).to_h
  end
end
