# Per-repository hotfix-sync detection (docs/plans/delivery-tracks-and-promotion.md
# Story 5/5A). Detects when the release branch (DeliveryPolicy#hotfix_sync_source_branch,
# normally the repository default branch) has commits the development track
# (DeliveryPolicy#hotfix_sync_target_branch) doesn't have yet — e.g. a direct
# hotfix commit or manually merged PR to `main` — and dispatches
# HotfixSyncDispatcher to mechanically sync them back.
class PollHotfixSyncJob < ApplicationJob
  queue_as :polling

  limits_concurrency to: 1, key: ->(repo_id, *) { "poll_hotfix_sync:#{repo_id}" }

  # GitHub-side failures that mean "we couldn't reach GitHub this tick," not
  # "there's nothing to sync." Mirrors the GitHub-related subset of
  # AutoRetryFailureClassifier::RETRYABLE_ERROR_CLASSES (see
  # PollMainBranchHealthJob's identical list).
  TRANSIENT_GITHUB_ERROR_CLASSES = [
    Octokit::ServerError,
    Faraday::TimeoutError,
    Faraday::ConnectionFailed
  ].freeze

  def perform(repository_id)
    repository = Repository.find_by(id: repository_id)
    return unless repository
    return if repository.archived?

    policy = DeliveryPolicy.for(repository: repository)
    return unless policy.hotfix_sync_enabled?

    source = policy.hotfix_sync_source_branch
    target = policy.hotfix_sync_target_branch
    return if source.blank? || target.blank? || source == target

    # A sync is already in flight (or open awaiting manual merge) for this
    # repository — wait for it to resolve instead of piling up duplicate
    # anchor Jobs every poll tick.
    return if HotfixSyncDispatcher.pending_for?(repository)

    client = GithubClient.for(repository: repository, user: repository.user)

    comparison = begin
      client.compare_commits(repository.slug, target, source)
    rescue *TRANSIENT_GITHUB_ERROR_CLASSES => e
      Rails.logger.warn(
        "[PollHotfixSyncJob] GitHub unreachable for #{repository.slug}: #{e.class}: #{e.message}"
      )
      return
    end

    return if comparison[:commits].empty?

    Rails.logger.info(
      "[PollHotfixSyncJob] #{repository.slug}: #{source} has #{comparison[:commits].size} commit(s) " \
      "not yet in #{target}; dispatching hotfix sync"
    )
    HotfixSyncDispatcher.call!(repository: repository, source_branch: source, target_branch: target)
  end
end
