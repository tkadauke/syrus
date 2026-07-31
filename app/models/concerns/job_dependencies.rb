module JobDependencies
  extend ActiveSupport::Concern

  def dependencies_satisfied?
    return false if epic.present? && !epic.releases_jobs_for_execution?
    return true if dependencies_overridden_at.present?

    dependencies.includes(:depends_on_job, :depends_on_epic).all? do |dependency|
      dependency.dependency_succeeded?
    end
  end

  def dependencies_satisfied_for_execution?
    return false if epic.present? && !epic.releases_jobs_for_execution?
    return true if dependencies_overridden_at.present?

    dependencies.includes(:depends_on_job, :depends_on_epic).all? do |dependency|
      dependency.execution_dependency_satisfied?
    end
  end

  def unsatisfied_dependencies
    dependencies.includes(:depends_on_epic, depends_on_job: :repository).reject do |dependency|
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
    start_pending_workflows_if_dependencies_satisfied!
  end
end
