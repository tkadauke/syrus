class PlannedExecutionPlanner
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
    project = loaded.config&.project
    capabilities = project&.capabilities
    return existing unless loaded.loaded? && capabilities&.to_h.present?

    PlannedExecutionRequirement.new(
      project_label: project.label.presence || project.id.presence || "Repository",
      target_label: TargetGraph.root_label.to_s,
      capabilities: capabilities,
      source: "inferred"
    )
  rescue StandardError => e
    Rails.logger.warn("[PlannedExecutionPlanner] defaulting #{job.slug || "Job##{job.id}"}: #{e.class}: #{e.message}")
    PlannedExecutionRequirement.from_record(job)
  end

  private

  attr_reader :job
end
