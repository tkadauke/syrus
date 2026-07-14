class PollMainBranchHealthJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(repo_id, *) { "poll_main_health:#{repo_id}" }

  def perform(repository_id)
    repository = Repository.find_by(id: repository_id)
    return unless repository
    return if repository.archived?
    return unless repository.main_branch_health_enabled?

    client = GithubClient.for(repository: repository, user: repository.user)

    sha = client.branch_head_sha(repository.slug, repository.default_branch)
    return unless sha

    sha_changed = sha != repository.last_health_checked_sha
    previous_health = repository.main_health
    grading_needed = sha != repository.last_graded_sha

    # Health is scoped to the default-branch SHA. When main advances, stale
    # healthy states from the prior SHA must not leak onto the new one while
    # GitHub checks or the main-grader workflow are still running. Broken states
    # are different: once work has been paused because main is broken, keep the
    # current signal broken until the replacement SHA gets a conclusive green
    # signal. Otherwise the UI and queue gate briefly look recovered while the
    # fix is still being validated.
    if sha_changed
      repository.update_columns(
        last_health_checked_sha: sha,
        ci_health: repository.ci_health_broken? ? "broken" : "unknown",
        grader_health: repository.grader_health_broken? ? "broken" : "unknown"
      )
      repository.reload
    end

    # Fire the grader workflow when the SHA hasn't been graded yet.
    # MainGraderWorkflowJob enforces at-most-one active grading job per repo;
    # if one is already running it will skip and PollMainBranchHealthJob will
    # retry on the next tick (grading_needed stays true until last_graded_sha
    # is updated by MainGraderWorkflowJob on successful job creation).
    MainGraderWorkflowJob.perform_later(repository.id, sha) if grading_needed

    # Skip CI health check when SHA unchanged, health is already known, and
    # grading is also up to date — nothing new to evaluate.
    return if !sha_changed && !repository.main_health_unknown? && !grading_needed


    already_recorded_no_ci = repository.ci_health_not_configured? && repository.last_health_checked_sha == sha
    summary = client.check_runs_summary_for(repository.slug, sha)

    unless summary[:any?]
      repository.update_columns(
        ci_health: "not_configured",
        last_health_checked_sha: sha
      )
      repository.reload
      unless already_recorded_no_ci
        MainBranchHealthCheck.record_ci_poll(
          repository: repository,
          sha: sha,
          ci_health: "not_configured",
          ci_failed_checks: []
        )
      end
      MainHealthChangedService.on_health_change!(repository) if repository.main_health != previous_health
      return
    end

    if summary[:pending?]
      # Checks still running. Keep ci_health unknown so later polls keep
      # refreshing this same SHA until GitHub reaches a terminal result.
      return
    end

    new_ci_health = if summary[:any_failed?]
      "broken"
    elsif summary[:all_passed?]
      "healthy"
    end

    if new_ci_health
      repository.update_columns(
        ci_health: new_ci_health,
        last_health_checked_sha: sha
      )
      MainBranchHealthCheck.record_ci_poll(
        repository: repository,
        sha: sha,
        ci_health: new_ci_health,
        ci_failed_checks: summary[:failed_checks]
      )
    end

    repository.reload
    if repository.main_health != previous_health
      MainHealthChangedService.on_health_change!(repository)
    end
  end
end
