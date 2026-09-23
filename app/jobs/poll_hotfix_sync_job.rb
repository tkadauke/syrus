# Per-repository hotfix-sync detection (docs/plans/complete/delivery-tracks-and-promotion.md
# Story 5/5A). Detects when the release branch (DeliveryPolicy#hotfix_sync_source_branch,
# normally the repository default branch) has commits the development track
# (DeliveryPolicy#hotfix_sync_target_branch) doesn't have yet — e.g. a direct
# hotfix commit or manually merged PR to `main` — and dispatches
# HotfixSyncDispatcher to mechanically sync them back.
class PollHotfixSyncJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  limits_concurrency to: 1, key: ->(repo_id, *) { "poll_hotfix_sync:#{repo_id}" }

  # A relation other than these means `source` has commits `target` lacks --
  # `:ahead`/`:behind` are from target's point of view, so `source` being
  # `:ahead` of `target` (or the two having `:diverged`) is what needs a sync.
  UNSYNCED_RELATIONS = %i[ahead diverged].freeze

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

    return unless source_ahead_of_target?(repository, source: source, target: target)

    Rails.logger.info(
      "[PollHotfixSyncJob] #{repository.slug}: #{source} has commits not yet in #{target}; dispatching hotfix sync"
    )
    HotfixSyncDispatcher.call!(repository: repository, source_branch: source, target_branch: target)
  end

  private

  def source_ahead_of_target?(repository, source:, target:)
    content = RepositoryContent.for(repository, user: repository.user)
    UNSYNCED_RELATIONS.include?(content.relation(base: content.resolve(target), head: content.resolve(source)))
  rescue RepositoryContent::UnknownRevision
    false
  rescue RepositoryContent::Unavailable => e
    Rails.logger.warn("[PollHotfixSyncJob] could not compare #{repository.slug}: #{e.class}: #{e.message}")
    false
  end
end
