class ImplementationCapabilityEscalation
  KIND = "implementation_capability_escalation".freeze
  EXECUTABLE_TARGET_KINDS = %w[formatter builder grader prepare generator repo_check].freeze

  Result = Data.define(
    :escalated?,
    :planned_capabilities,
    :required_capabilities,
    :most_constrained_target,
    :most_constrained_targets,
    :mismatched_targets,
    :mismatches,
    :affected_targets
  ) do
    def warning_title
      "Implementation touched targets requiring capabilities beyond the planned worker"
    end

    def evidence
      {
        "planned_capabilities" => planned_capabilities,
        "required_capabilities" => required_capabilities,
        "most_constrained_target" => target_evidence(most_constrained_target),
        "most_constrained_targets" => most_constrained_targets.map { |entry| target_evidence(entry) },
        "mismatched_targets" => mismatched_targets.map { |entry| target_evidence(entry) },
        "mismatches" => mismatches,
        "affected_targets" => affected_targets.map { |entry| target_evidence(entry) }
      }.compact
    end

    def suggested_prompt
      target_label = most_constrained_target.fetch("target_label")
      <<~PROMPT.strip
        Re-run or continue this implementation on a worker that satisfies the affected target capabilities.

        The original implementation workflow was planned with #{planned_capabilities.inspect}, but the diff affected #{target_label}, which requires #{required_capabilities.inspect}. Do not move a mutable workspace across platforms unless an explicit checkpoint or handoff mechanism is used.

        Retry the implementation on a capable primary worker, split the work by platform, or confirm that platform-specific graders fully validate the change before dismissing this warning.
      PROMPT
    end

    private

    def target_evidence(entry)
      return nil unless entry

      entry.slice(
        "target_label",
        "project_id",
        "kind",
        "capabilities",
        "affected_reason",
        "owner_config_path"
      ).compact
    end
  end

  def self.call(workflow:, graph:, changed_files:)
    new(workflow: workflow, graph: graph, changed_files: changed_files).call
  end

  def initialize(workflow:, graph:, changed_files:)
    @workflow = workflow
    @graph = graph
    @changed_files = Array(changed_files).map(&:to_s)
  end

  def call
    affected = affected_capability_targets
    constrained = most_constrained_targets(affected)
    return no_escalation(affected) if constrained.empty?

    mismatched = mismatched_targets(constrained)
    most_constrained = mismatched.first || constrained.first
    required = most_constrained.fetch("capabilities", {})
    mismatches = mismatches_for(mismatched)

    Result.new(
      escalated?: mismatched.any?,
      planned_capabilities: planned_capabilities,
      required_capabilities: required,
      most_constrained_target: most_constrained,
      most_constrained_targets: constrained,
      mismatched_targets: mismatched,
      mismatches: mismatches,
      affected_targets: affected
    )
  end

  private

  attr_reader :workflow, :graph, :changed_files

  def planned_capabilities
    @planned_capabilities ||= PlannedExecutionRequirement.from_record(workflow).capabilities
  end

  def no_escalation(affected)
    Result.new(
      escalated?: false,
      planned_capabilities: planned_capabilities,
      required_capabilities: {},
      most_constrained_target: nil,
      most_constrained_targets: [],
      mismatched_targets: [],
      mismatches: [],
      affected_targets: affected
    )
  end

  def affected_capability_targets
    graph.targets.values.filter_map do |target|
      next unless EXECUTABLE_TARGET_KINDS.include?(target.kind)
      next if target.capabilities.blank? || target.capabilities.empty?

      selection = graph.affected(target.label, changed_files: changed_files)
      next unless selection.affected

      target_entry(target, selection.reason)
    end
  end

  def target_entry(target, affected_reason)
    {
      "target_label" => target.label.to_s,
      "project_id" => target.project_id,
      "kind" => target.kind,
      "capabilities" => target.capabilities.to_h,
      "affected_reason" => affected_reason,
      "owner_config_path" => target.owner_config_path
    }
  end

  def most_constrained_targets(targets)
    max_weight = targets.map { |target| capability_weight(target.fetch("capabilities", {})) }.max
    return [] unless max_weight

    targets.select { |target| capability_weight(target.fetch("capabilities", {})) == max_weight }
  end

  def capability_weight(capabilities)
    TargetGraph::ExecutionCapabilities::DIMENSIONS.sum do |dimension|
      Array(capabilities[dimension]).size
    end
  end

  def mismatched_targets(targets)
    targets.filter_map do |target|
      mismatches = capability_mismatches(planned_capabilities, target.fetch("capabilities", {}))
      next if mismatches.empty?

      target.merge("mismatches" => mismatches)
    end
  end

  def mismatches_for(targets)
    targets.flat_map do |target|
      target.fetch("mismatches").map { |mismatch| mismatch.merge("target_label" => target.fetch("target_label")) }
    end
  end

  def capability_mismatches(planned, required)
    TargetGraph::ExecutionCapabilities::DIMENSIONS.filter_map do |dimension|
      missing = missing_values(planned[dimension], required[dimension])
      next if missing.empty?

      {
        "dimension" => dimension,
        "planned" => Array(planned[dimension]),
        "required" => Array(required[dimension]),
        "missing" => missing
      }
    end
  end

  def missing_values(planned_values, required_values)
    planned_values = Array(planned_values).map(&:to_s)
    required_values = Array(required_values).map(&:to_s)
    return [] if required_values.empty?
    return [] if required_values == [ TargetGraph::ExecutionCapabilities::CONFLICTING_WILDCARD ]
    return [] if planned_values.include?(TargetGraph::ExecutionCapabilities::CONFLICTING_WILDCARD)

    required_values - planned_values
  end
end
