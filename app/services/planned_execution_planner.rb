class PlannedExecutionPlanner
  # Execution capabilities are declared, never guessed. Whoever creates the
  # work says where it has to run -- the proposing agent through
  # `planned_execution`, an operator through the API, or the repository through
  # `.syrus.yml` -- and anything undeclared runs on the Linux default.
  #
  # This used to infer them by matching a Job's title and body against keyword
  # lists, and that could not be made to work. A bug report filed from a phone
  # matched "iphone" inside a User-Agent. A Kotlin/JVM Job that said iOS was
  # "intentionally out of scope" matched on the sentence excluding it. Nothing
  # in the fleet advertises macOS, so each one blocked on `no_capable_worker`
  # and retried every couple of minutes indefinitely. Each round of teaching
  # the matcher a new exception produced a new escape, because a regex cannot
  # read intent. The matching is therefore gone rather than narrowed, and it
  # must not come back: a capability nobody declared is not a capability.
  def self.for_job(job)
    new(job).call
  end

  def initialize(job)
    @job = job
  end

  def call
    existing = PlannedExecutionRequirement.from_record(job)
    # Anything already carrying a non-default source was declared by someone --
    # the agent, an operator, the ingestion classifier -- and is authoritative.
    return existing unless existing.source == "defaulted"

    declared_repository_requirement || existing
  rescue StandardError => e
    Rails.logger.warn("[PlannedExecutionPlanner] defaulting #{job.slug || "Job##{job.id}"}: #{e.class}: #{e.message}")
    PlannedExecutionRequirement.from_record(job)
  end

  private

  attr_reader :job

  # `.syrus.yml` project capabilities are the repository declaring what every
  # Job in it needs, so they apply without consulting the Job's text at all.
  #
  # Target and grade-step capabilities are deliberately not consulted: choosing
  # one of those for a particular Job meant matching the Job's prose against
  # the target's name, which is exactly the inference this class no longer
  # does. A Job that needs a specific target says so through
  # `planned_execution`.
  #
  # The stored source stays "inferred" for continuity with existing rows; it
  # means "derived from repository configuration", not derived from the text.
  def declared_repository_requirement
    loaded = RepoDefaultBranchSyrusYml.for_job(job)
    return nil unless loaded.loaded?

    project = loaded.config&.project
    return nil if project&.capabilities&.to_h.blank?

    PlannedExecutionRequirement.new(
      project_label: project.label.presence || project.id.presence || "Repository",
      target_label: TargetGraph.root_label.to_s,
      capabilities: project.capabilities,
      source: "inferred"
    )
  end
end
