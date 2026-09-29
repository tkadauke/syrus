# Fan-out for hotfix-sync detection (docs/plans/complete/delivery-tracks-and-promotion.md
# Story 5/5A). Mirrors PollAllDeploymentStagesJob: hotfix-sync opt-in lives in
# `.syrus.yml`, not a Repository boolean column, so this reads DeliveryPolicy
# per repository instead of filtering with a `where(...)` clause.
class PollAllHotfixSyncsJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  def perform
    return if AppSetting.polling_paused?

    repository_ids = Repository.active.find_each.filter_map do |repository|
      repository.id if DeliveryPolicy.for(repository: repository).hotfix_sync_enabled?
    end
    PollHotfixSyncJob.perform_later_missing_simple_args(repository_ids.map { |id| [ id ] })
  end
end
