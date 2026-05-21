class LandingQueueProcessor
  Entry = Struct.new(:job, :position, :blocked_reason, :waiting_for, keyword_init: true) do
    def eligible?
      blocked_reason.blank?
    end

    def job_id = job.id
  end

  def self.call = new.call

  def self.entries(scope = Job.all)
    new.entries(scope)
  end

  # Try to land a specific Job right now. Used by callers that have
  # just made a Job land-able and don't want to wait for the next
  # recurring tick — e.g. a Rebase workflow's success callback when
  # the Job is still approved. Returns the dispatched Workflow or
  # nil if the Job wasn't landable (not approved, blockage present,
  # landing already in progress for the same repository).
  def self.try_land!(job) = new.try_land!(job)

  def try_land!(job)
    return if landing_in_progress_for_repository?(job.repository_id)
    return unless job.approved?
    return unless blockage_for(job)[:blocked_reason].blank?

    land(job)
  end

  def call
    occupied_repo_ids = Set.new(Job.landing.pluck(:repository_id))
    landed_workflows = []

    entries(Job.approved.includes(:user, :repository, :epic, :parent_job, dependencies: :depends_on_job)).each do |entry|
      next if occupied_repo_ids.include?(entry.job.repository_id)
      next unless entry.eligible?

      workflow = land(entry.job)
      next unless workflow

      landed_workflows << workflow
      occupied_repo_ids << entry.job.repository_id
    end

    landed_workflows.first
  end

  def entries(scope = Job.all)
    ordered_queue(scope).map.with_index(1) do |job, position|
      Entry.new(job: job, position: position, **blockage_for(job))
    end
  end

  private

  def ordered_queue(scope)
    scope.where(state: %w[ approved landing ])
         .includes(:user, :repository, :epic, :parent_job, dependencies: :depends_on_job)
         .order(Arel.sql("COALESCE(jobs.approved_at, jobs.updated_at) ASC"), :id)
  end

  def land(job)
    workflow = nil
    landed = false
    Job.transaction do
      job.lock!
      raise ActiveRecord::Rollback if landing_in_progress_for_repository?(job.repository_id)
      raise ActiveRecord::Rollback unless job.approved?
      raise ActiveRecord::Rollback unless blockage_for(job)[:blocked_reason].blank?

      job.start_landing!
      job.save!
      workflow = Workflows::AutoMerge.instantiate(job: job)
      audit(job, "landing_queue: dispatching auto-merge workflow ##{workflow.id}")
      landed = true
    end
    return unless landed

    StepDispatcher.start_workflow(workflow)
    workflow
  end

  def landing_in_progress_for_repository?(repository_id)
    Job.landing.where(repository_id: repository_id).exists?
  end

  def blockage_for(job)
    return { blocked_reason: nil, waiting_for: nil } if job.landing?
    return blocked("landing paused") if job.user.landing_paused?
    return blocked("repository archived") if job.repository.archived?
    # Don't burn a fail_landing cycle on a Job whose repo isn't set
    # up for auto-merge — that wipes the operator's approval without
    # surfacing the real misconfiguration. Keep the Job in :approved
    # with a clear blocked_reason; once the repo flips
    # auto_merge_enabled=true the queue picks it up immediately.
    return blocked("auto-merge not enabled for repository") unless job.repository.auto_merge_enabled?
    return blocked("missing pull request") if job.pr_number.blank?
    return blocked("active workflow") if job.workflows.active.exists?
    return blocked("waiting for Epic to release") if job.blocked_by_epic_before_execution?

    parent = job.parent_job
    if parent && !merged?(parent)
      return blocked("waiting for ##{parent.issue_number || parent.id} to merge", parent)
    end

    dependency = job.dependencies_overridden_at.present? ? nil : unmerged_dependency(job)
    if dependency
      waiting = dependency.pending? ? dependency.unresolved_slug : dependency.depends_on_job
      return blocked("waiting for #{dependency_label(waiting)} to merge", waiting)
    end

    { blocked_reason: nil, waiting_for: nil }
  end

  def blocked(reason, waiting_for = nil)
    { blocked_reason: reason, waiting_for: waiting_for }
  end

  def merged?(job)
    job.closed? && job.closure_reason == "pr_merged"
  end

  def unmerged_dependency(job)
    job.dependencies.includes(:depends_on_job).find do |dependency|
      dependency.pending? || !merged?(dependency.depends_on_job)
    end
  end

  def dependency_label(waiting)
    return waiting if waiting.is_a?(String)

    "##{waiting.issue_number || waiting.id}"
  end

  def audit(job, message)
    run = job.current_run
    return unless run

    run.job_logs.create!(
      chunk: message,
      sequence: (run.job_logs.maximum(:sequence) || -1) + 1,
      kind: "system"
    )
  end
end
