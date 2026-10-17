class WorkEngineReconcilerActivityPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = RetentionPruner.call(
      scope: WorkEngineReconcilerActivityEvent.prunable,
      retention_key: :work_engine_reconciler_activity,
      cutoff: WorkEngineReconcilerActivityEvent.retention_cutoff
    )
    Rails.logger.info("[WorkEngineReconcilerActivityPruneJob] deleted #{deleted} reconciler activity events") if deleted > 0
  end
end
