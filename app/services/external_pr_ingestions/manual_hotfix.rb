module ExternalPrIngestions
  # Story 5/5A/10: a PR/merge that landed directly on the release branch
  # without going through a local Job — a hand-committed hotfix, or a
  # manually merged PR. This feeds hotfix-sync detection rather than
  # becoming ordinary review work: no `external_pr` Job is created here.
  # `PollHotfixSyncJob` would eventually notice the same branch divergence
  # on its own 5-minute poll tick; dispatching eagerly here just closes that
  # gap instead of waiting on the next tick. `HotfixSyncDispatcher.call!` is
  # idempotent against an already-pending sync (`.pending_for?`), so this
  # never piles up duplicate anchor Jobs alongside the poller.
  class ManualHotfix < Base
    def ingest!(repository:, pr:, fork_pr:)
      policy = DeliveryPolicy.for(repository: repository)
      if policy.hotfix_sync_enabled? && !HotfixSyncDispatcher.pending_for?(repository)
        Rails.logger.info(
          "[ExternalPrIngestions::ManualHotfix] #{repository.slug}##{pr.number} recognized as a manual hotfix; " \
          "triggering hotfix-sync detection"
        )
        HotfixSyncDispatcher.call!(repository: repository)
      end

      nil
    end
  end
end
