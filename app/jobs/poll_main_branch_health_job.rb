class PollMainBranchHealthJob < ApplicationJob
  include SkipIfPending
  include GithubPollingRateLimitGuard

  queue_as :polling

  limits_concurrency to: 1, key: ->(repo_id, *) { "poll_main_health:#{repo_id}" }

  # GitHub-side failures that mean "we couldn't reach GitHub this tick," not
  # "main is broken." Mirrors the GitHub-related subset of
  # AutoRetryFailureClassifier::RETRYABLE_ERROR_CLASSES.
  TRANSIENT_GITHUB_ERROR_CLASSES = [
    Octokit::ServerError,
    Faraday::TimeoutError,
    Faraday::ConnectionFailed
  ].freeze

  def perform(repository_id, manual: false)
    repository = Repository.find_by(id: repository_id)
    return unless repository
    return if repository.archived?
    return unless repository.main_branch_health_enabled?
    return if github_polling_rate_limited?(repository, user: repository.user, manual: manual, retry_args: [ repository_id ])

    # Grading main is the instance's work, not the repository owner's; see
    # InstanceIdentity. It still runs as the owner, but a repository with no
    # owner is reported rather than failing silently.
    identity = InstanceIdentity.for_repository(repository)
    if identity.missing?
      Rails.logger.warn("[PollMainBranchHealthJob] #{repository.slug} has no identity for instance work; skipping")
      return
    end

    client = GithubClient.for(repository: repository, user: identity.user)

    with_github_polling_rate_limit_backoff(repository, user: repository.user, manual: manual, retry_args: [ repository_id ]) do
      client.clear_api_blocked!
      health_branches(repository).each do |branch|
        poll_branch(repository, client, branch)
      end
      repository.reset_main_health_poll_error_streak!
    rescue *TRANSIENT_GITHUB_ERROR_CLASSES => e
      handle_transient_github_error!(repository, e)
    end
  end

  private

  def health_branches(repository)
    DeliveryPolicy.for(repository: repository).tracks.values.map(&:branch).compact.uniq
  end

  def poll_branch(repository, client, branch)
    default_track_branch = branch == repository.default_branch
    branch, sha = health_head(repository, client, branch)
    return unless sha

    latest = MainBranchHealthCheck.where(repository: repository, branch: branch).recent.first
    current = MainBranchHealthCheck.where(repository: repository, branch: branch, sha: sha)
                                   .where.not(source: "concern_quorum").recent.first
    previous_sha = latest&.sha || (repository.last_health_checked_sha if default_track_branch)
    if default_track_branch && repository.last_health_checked_sha != sha
      repository.update_columns(
        last_health_checked_sha: sha,
        ci_health: repository.ci_health_broken? ? "broken" : "unknown",
        grader_health: repository.grader_health_broken? ? "broken" : "unknown"
      )
      repository.reload
    end
    grading_needed = !MainBranchHealthCheck.conclusive_grader_result_exists?(
      repository: repository, branch: branch, sha: sha
    )
    if default_track_branch && repository.last_graded_sha == sha
      grading_needed = false
    end

    if grading_needed
      enqueue_main_grader(
        repository,
        sha,
        previous_main_sha: (previous_sha if previous_sha != sha),
        health_branch: branch
      )
    end

    if current && current.ci_health.in?(%w[healthy broken inconclusive]) && !grading_needed
      MainHealthChangedService.ensure_repair_job!(repository) if default_track_branch && repository.main_health_broken?
      return
    end
    if default_track_branch && repository.last_health_checked_sha == sha &&
        repository.last_ci_evaluated_sha == sha && !repository.main_health_unknown? &&
        !repository.ci_health_not_configured? && !grading_needed
      MainHealthChangedService.ensure_repair_job!(repository) if repository.main_health_broken?
      return
    end
    summary = client.main_branch_check_runs_summary_for(repository.slug, sha)
    if summary[:pending?]
      if default_track_branch && repository.ci_health_not_configured?
        repository.update_columns(ci_health: "unknown", last_ci_evaluated_sha: nil)
      end
      return
    end

    ci_health = if !summary[:any?]
      "not_configured"
    elsif summary[:any_failed?]
      "broken"
    elsif summary[:all_passed?]
      "healthy"
    elsif summary[:any_cancelled?]
      "inconclusive"
    end
    return unless ci_health
    return if ci_health == "not_configured" && current&.ci_health == "not_configured"

    previous_health = repository.main_health if default_track_branch
    MainBranchHealthCheck.record_ci_poll(
      repository: repository,
      branch: branch,
      sha: sha,
      ci_health: ci_health,
      ci_failed_checks: summary[:failed_checks] || []
    )
    update_default_branch_summary!(repository, branch, sha, ci_health, previous_health) if default_track_branch
  end

  def health_head(repository, client, branch)
    [ branch, client.branch_head_sha(repository.slug, branch) ]
  rescue Octokit::NotFound
    raise unless branch == repository.default_branch

    fallback = client.repository_default_branch(repository.slug).to_s.strip
    raise if fallback.blank? || fallback == branch

    Rails.logger.warn(
      "[PollMainBranchHealthJob] #{repository.slug} configured main-health branch #{branch.inspect} " \
      "was not found on GitHub; checking GitHub default branch #{fallback.inspect} for this poll"
    )
    [ fallback, client.branch_head_sha(repository.slug, fallback) ]
  end

  def update_default_branch_summary!(repository, branch, sha, ci_health, previous_health)
    check = MainBranchHealthCheck.where(repository: repository, branch: branch, sha: sha)
                                .where.not(source: "concern_quorum").recent.first
    repository.update_columns(
      last_health_checked_sha: sha,
      last_ci_evaluated_sha: sha,
      ci_health: ci_health,
      grader_health: check&.grader_health || "unknown"
    )
    repository.reload
    if repository.main_health != previous_health
      MainHealthChangedService.on_health_change!(repository)
    elsif repository.main_health_broken?
      MainHealthChangedService.ensure_repair_job!(repository)
    end
  end

  def enqueue_main_grader(repository, sha, previous_main_sha: nil, health_branch: nil)
    kwargs = {}
    kwargs[:previous_main_sha] = previous_main_sha if previous_main_sha.present?
    kwargs[:base_branch] = health_branch if health_branch.present? && health_branch != repository.default_branch
    if kwargs.empty?
      MainGraderWorkflowJob.perform_later(repository.id, sha)
    else
      MainGraderWorkflowJob.perform_later(repository.id, sha, **kwargs)
    end
  end

  # A single failed request is normal poll-to-poll noise — the next scheduled
  # tick retries. Only a sustained streak of consecutive failures degrades an
  # already-broken ci_health to "inconclusive" (never fabricates "healthy"
  # from missing data), which lets MainHealthChangedService's existing
  # inconclusive path resume landing and notify the operator that the cause
  # may be a GitHub-side outage rather than unfixed code.
  def handle_transient_github_error!(repository, error)
    Rails.logger.warn(
      "[PollMainBranchHealthJob] GitHub unreachable for #{repository.slug}: #{error.class}: #{error.message}"
    )

    repository.record_main_health_poll_error!
    return unless repository.main_health_poll_outage?
    return unless repository.ci_health_broken?

    previous_health = repository.main_health
    repository.update_columns(ci_health: "inconclusive")
    repository.reload
    MainHealthChangedService.on_health_change!(repository) if repository.main_health != previous_health
  end
end
