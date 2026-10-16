class MainBranchHealthCheckPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = RetentionPruner.call(
      scope: MainBranchHealthCheck.pruneable,
      retention_key: :main_branch_health_check,
      cutoff: MainBranchHealthCheck.retention_cutoff
    )
    Rails.logger.info("[MainBranchHealthCheckPruneJob] deleted #{deleted} main branch health checks") if deleted > 0
  end
end
