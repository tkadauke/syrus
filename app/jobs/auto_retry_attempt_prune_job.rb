class AutoRetryAttemptPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    pruned = AutoRetryAttempt.prune_stale_pending!
    Rails.logger.info("[AutoRetryAttemptPruneJob] pruned #{pruned} stale pending auto retry attempts") if pruned > 0
  end
end
