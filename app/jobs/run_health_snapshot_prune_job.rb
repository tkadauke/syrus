class RunHealthSnapshotPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = RunHealthSnapshot.prunable.delete_all
    Rails.logger.info("[RunHealthSnapshotPruneJob] deleted #{deleted} run health snapshots") if deleted > 0
  end
end
