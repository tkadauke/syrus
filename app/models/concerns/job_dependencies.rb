module JobDependencies
  extend ActiveSupport::Concern

  def dependencies_satisfied?
    return false if epic.present? && !epic.releases_jobs_for_execution?
    return true if dependencies_overridden_at.present?

    preloaded_dependencies(:depends_on_job, :depends_on_epic).all? do |dependency|
      dependency.dependency_succeeded?
    end
  end

  def dependencies_satisfied_for_execution?
    return false if epic.present? && !epic.releases_jobs_for_execution?
    return true if dependencies_overridden_at.present?

    preloaded_dependencies(:depends_on_job, :depends_on_epic).all? do |dependency|
      dependency.execution_dependency_satisfied?
    end
  end

  def dependencies_failed_for_execution?
    failed_dependencies_for_execution.any?
  end

  def failed_dependencies_for_execution
    preloaded_dependencies(:depends_on_job, :depends_on_epic).select do |dependency|
      dependency_terminal_unsuccessful?(dependency)
    end
  end

  def unsatisfied_dependencies
    preloaded_dependencies(:depends_on_epic, depends_on_job: :repository).reject do |dependency|
      dependency.dependency_succeeded?
    end
  end

  def dependency_succeeded?
    # :merged was removed; the merge path now closes the Job with
    # closure_reason "pr_merged". SUCCESSFUL_CLOSURE_REASONS already
    # includes that, so the (closed? && reason in set) branch covers
    # both kinds of successful close.
    closed? && Job::SUCCESSFUL_CLOSURE_REASONS.include?(closure_reason)
  end
  def force_run_dependencies!(user:)
    update!(
      dependencies_overridden_at: Time.current,
      dependencies_overridden_by_user: user
    )
    log_dependency_override!(user)
    clear_dependency_start_blocks!
    if may_advance_after_triage?
      advance_after_triage!
    else
      start_pending_workflows_if_dependencies_satisfied!
    end
  end

  private

  def clear_dependency_start_blocks!
    dependency_blocked_workflows.each do |workflow|
      StepDispatcher.clear_start_blocked!(workflow, StepDispatcher::STACK_BLOCK_REASON)
      StepDispatcher.clear_start_blocked!(workflow, "dependency_failed")
    end
  end

  def dependency_blocked_workflows
    WorkUnits::Ownership
      .active_units_for_job(self)
      .filter_map(&:workflow)
      .select(&:queued?)
      .uniq(&:id)
  end

  def dependency_terminal_unsuccessful?(dependency)
    return false if dependency.dependency_succeeded?

    if dependency.depends_on_job
      dependency.depends_on_job.closed?
    elsif dependency.depends_on_epic
      dependency.depends_on_epic.archived?
    else
      false
    end
  end

  def preloaded_dependencies(*associations)
    records = dependencies.loaded? ? dependencies.to_a : dependencies.includes(*associations).to_a
    ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call if records.any?
    records
  end
end
