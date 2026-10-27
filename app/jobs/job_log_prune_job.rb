class JobLogPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = RetentionPruner.call(
      scope: JobLog.prunable,
      retention_key: :job_log,
      cutoff: JobLog.retention_cutoff
    )
    Rails.logger.info("[JobLogPruneJob] deleted #{deleted} job logs") if deleted > 0
  end
end
