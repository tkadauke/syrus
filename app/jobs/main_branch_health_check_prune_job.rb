class MainBranchHealthCheckPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = MainBranchHealthCheck.pruneable.delete_all
    Rails.logger.info("[MainBranchHealthCheckPruneJob] deleted #{deleted} main branch health checks") if deleted > 0
  end
end
