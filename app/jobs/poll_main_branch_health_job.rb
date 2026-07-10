class PollMainBranchHealthJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(repo_id, *) { "poll_main_health:#{repo_id}" }

  def perform(repository_id)
    repository = Repository.find_by(id: repository_id)
    return unless repository
    return if repository.archived?

    client = GithubClient.for(repository: repository, user: repository.user)

    sha = client.branch_head_sha(repository.slug, repository.default_branch)
    return unless sha

    sha_changed = sha != repository.last_health_checked_sha

    # Skip when SHA unchanged and health is already known — no new information.
    return if !sha_changed && !repository.main_health_unknown?

    # Fire the grader workflow against the new SHA so grader_health stays current.
    MainGraderWorkflowJob.perform_later(repository.id, sha) if sha_changed

    summary = client.check_runs_summary_for(repository.slug, sha)

    # No CI configured on this repo — record the SHA and stop.
    return repository.update_columns(last_health_checked_sha: sha) unless summary[:any?]

    if summary[:pending?]
      # Checks still running; record the SHA so we know where we are but
      # leave ci_health unchanged until they complete.
      repository.update_columns(last_health_checked_sha: sha)
      return
    end

    previous_health = repository.main_health

    if summary[:any_failed?]
      repository.update_columns(
        ci_health: "broken",
        last_health_checked_sha: sha
      )
    elsif summary[:all_passed?]
      repository.update_columns(
        ci_health: "healthy",
        last_health_checked_sha: sha
      )
    end

    repository.reload
    if repository.main_health != previous_health && repository.main_health_broken?
      MainHealthChangedService.on_health_change!(repository)
    end
  end
end
