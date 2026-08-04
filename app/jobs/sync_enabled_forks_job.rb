# Scheduled fan-out: enqueues a SyncForkJob for every fork that has auto-sync
# enabled and an in-instance upstream. Runs from config/recurring.yml so a
# fork's default branch stays current with its upstream even when no Jobs are
# running — keeping main-branch health/grader detection from going stale.
class SyncEnabledForksJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform
    Repository.where(fork_auto_sync_enabled: true)
              .where.not(upstream_repository_id: nil)
              .pluck(:id)
              .each { |repository_id| SyncForkJob.perform_later(repository_id) }
  end
end
