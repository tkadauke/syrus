class WorkEngineReconcilerActivityPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    scope = WorkEngineReconcilerActivityEvent.prunable
    RetentionArchiver.call(
      retention_key: :work_engine_reconciler_activity,
      scope: scope,
      cutoff: WorkEngineReconcilerActivityEvent.retention_cutoff
    )
    deleted = scope.delete_all
    Rails.logger.info("[WorkEngineReconcilerActivityPruneJob] deleted #{deleted} reconciler activity events") if deleted > 0
  end
end
