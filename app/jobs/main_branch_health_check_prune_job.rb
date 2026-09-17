class MainBranchHealthCheckPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    scope = MainBranchHealthCheck.pruneable
    RetentionArchiver.call(
      retention_key: :main_branch_health_check,
      scope: scope,
      cutoff: MainBranchHealthCheck.retention_cutoff
    )
    deleted = scope.delete_all
    Rails.logger.info("[MainBranchHealthCheckPruneJob] deleted #{deleted} main branch health checks") if deleted > 0
  end
end
