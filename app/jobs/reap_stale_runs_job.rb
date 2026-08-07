class ReapStaleRunsJob < ApplicationJob
  include SkipIfPending

  queue_as :control_plane
  limits_concurrency to: 1, key: "reap_stale_runs", duration: 10.minutes, on_conflict: :discard

  # Grace period shared with WorkEngine::Reconciler, which reads this constant.
  ORPHAN_RUN_GRACE_PERIOD = 2.minutes

  def perform
    WorkEngine::Reconciler.request(source: self.class.name)
    Rails.logger.info("[ReapStaleRunsJob] delegated to unified work-engine reconciler")
  end
end
