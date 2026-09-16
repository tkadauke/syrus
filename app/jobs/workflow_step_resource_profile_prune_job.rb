# WorkflowStepResourceProfiles::Refresh already deletes stale profiles as
# part of its hourly refresh (WorkflowStepResourceProfileRefreshJob), so this
# job is normally a no-op in practice. It exists as an explicit, independently
# schedulable safety net — following the same PruneJob shape every other
# retention-backed table gets — for the case where refresh stops running but
# pruning should still happen.
class WorkflowStepResourceProfilePruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = WorkflowStepResourceProfile.stale.delete_all
    Rails.logger.info("[WorkflowStepResourceProfilePruneJob] deleted #{deleted} stale workflow step resource profiles") if deleted > 0
  end
end
