class RunHealthSnapshotPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = RetentionPruner.call(
      scope: RunHealthSnapshot.prunable,
      retention_key: :run_health_snapshot,
      cutoff: RunHealthSnapshot.retention_cutoff
    )
    Rails.logger.info("[RunHealthSnapshotPruneJob] deleted #{deleted} run health snapshots") if deleted > 0
  end
end
