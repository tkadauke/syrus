class RunHealthSnapshotPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    scope = RunHealthSnapshot.prunable
    RetentionArchiver.call(retention_key: :run_health_snapshot, scope: scope, cutoff: RunHealthSnapshot.retention_cutoff)
    deleted = scope.delete_all
    Rails.logger.info("[RunHealthSnapshotPruneJob] deleted #{deleted} run health snapshots") if deleted > 0
  end
end
