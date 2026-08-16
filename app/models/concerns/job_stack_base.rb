module JobStackBase
  extend ActiveSupport::Concern

  def effective_base_branch
    # `target_branch` is an explicit operator/skill-set override (e.g. a
    # `promote`/`backport` skill Job that must PR against a specific branch
    # regardless of repo topology). It is unrelated to `stack_base == "main"`
    # below, which means "force base off the repository's default branch" —
    # a `stack_base` enum value that happens to be the literal string "main"
    # because that's this repo's own default branch name, not a reference to
    # any branch named "main" in general. A Job with an explicit
    # `target_branch` isn't part of stack topology at all, so it short-
    # circuits every other check here, including `stack_base_forces_main?`.
    return target_branch if target_branch.present?

    return base_default_branch if stack_base_forces_main?

    if parent_job.present? &&
        parent_job.open? &&
        parent_job.pr_number.present? &&
        parent_job.branch_name.present? &&
        !parent_job.dependency_succeeded?
      return parent_job.branch_name
    end

    parent = dependencies.includes(:depends_on_job).map(&:depends_on_job).compact.find do |dependency_job|
      dependency_job.open? &&
        dependency_job.pr_number.present? &&
        dependency_job.branch_name.present? &&
        !dependency_job.dependency_succeeded?
    end

    parent&.branch_name.presence || base_default_branch
  end

  # The repository whose default branch is this Job's base. For a fork with an
  # in-instance upstream, that's the upstream; otherwise the Job's repository.
  def base_repository
    repository&.base_repository
  end

  def base_default_branch
    repository&.base_default_branch
  end

  # True when the work branch (and diff, and PR base) should be based on the
  # in-instance upstream's default branch — a fork contributing to upstream.
  # False for non-forks, forks without an in-instance upstream, and stacked
  # children (which base on their parent branch, not the upstream default).
  def base_on_upstream_default?
    return false unless repository&.fork_syncable?
    return false if in_fork_review_mode?  # staging fork-review keeps its own base

    effective_base_branch == base_default_branch
  end

  def stack_ready_for_execution?
    return true if dependencies_overridden_at.present?

    JobStackResolver.new(self).ready?
  end

  def resolve_stack_parent!
    JobStackResolver.new(self).resolve!
  end

  def stack_base_forces_main?
    stack_base_main? && !epic_internal_dependency?
  end
end
