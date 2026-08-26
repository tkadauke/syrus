# Fan-out for hotfix-sync detection (docs/plans/delivery-tracks-and-promotion.md
# Story 5/5A). Mirrors PollAllDeploymentStagesJob: hotfix-sync opt-in lives in
# `.syrus.yml`, not a Repository boolean column, so this reads DeliveryPolicy
# per repository instead of filtering with a `where(...)` clause.
class PollAllHotfixSyncsJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  def perform
    return if AppSetting.polling_paused?

    Repository.active.find_each do |repository|
      next unless DeliveryPolicy.for(repository: repository).hotfix_sync_enabled?

      PollHotfixSyncJob.perform_later(repository.id)
    end
  end
end
