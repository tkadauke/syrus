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

  def call
    return if landing_in_progress?

    entries(Job.approved.includes(:user, :repository, :epic, :parent_job, dependencies: :depends_on_job)).each do |entry|
      next unless entry.eligible?

      return land(entry.job)
    end
    nil
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
      raise ActiveRecord::Rollback if landing_in_progress?

      job.lock!
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

  def landing_in_progress?
    Job.landing.exists? || Workflow.active.where(trigger_kind: "auto_merge").exists?
  end

  def blockage_for(job)
    return { blocked_reason: nil, waiting_for: nil } if job.landing?
    return blocked("landing paused") if job.user.landing_paused?
    return blocked("repository archived") if job.repository.archived?
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
