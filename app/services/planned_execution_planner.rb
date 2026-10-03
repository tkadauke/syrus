class PlannedExecutionPlanner
  AmbiguousRequest = Class.new(StandardError)

  def self.for_job(job)
    new(job).call
  end

  def initialize(job)
    @job = job
  end

  def call
    existing = PlannedExecutionRequirement.from_record(job)
    return existing unless existing.source == "defaulted"

    loaded = RepoDefaultBranchSyrusYml.for_job(job)
    analyzed = PlannedExecutionRequestAnalyzer.call(job: job, loaded_config: loaded, source: "prompt")
    raise AmbiguousRequest, analyzed.ambiguous_reason if analyzed.ambiguous?

    log_warning(analyzed.warning) if analyzed.warning
    return analyzed.requirement if analyzed.requirement

    project = loaded.config&.project
    capabilities = project&.capabilities
    return existing unless loaded.loaded? && capabilities&.to_h.present?

    PlannedExecutionRequirement.new(
      project_label: project.label.presence || project.id.presence || "Repository",
      target_label: TargetGraph.root_label.to_s,
      capabilities: capabilities,
      source: "inferred"
    )
  rescue AmbiguousRequest
    raise
  rescue StandardError => e
    Rails.logger.warn("[PlannedExecutionPlanner] defaulting #{job.slug || "Job##{job.id}"}: #{e.class}: #{e.message}")
    PlannedExecutionRequirement.from_record(job)
  end

  private

  attr_reader :job

  def log_warning(message)
    Rails.logger.warn("[PlannedExecutionPlanner] #{job.slug || "Job##{job.id}"}: #{message}")
  end
end
