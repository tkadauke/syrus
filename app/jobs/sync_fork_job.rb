# Syncs one fork's default branch with its in-instance upstream via
# ForkSyncService. Enqueued by SyncEnabledForksJob (scheduled auto-sync) and
# by the repository "Sync now" action.
class SyncForkJob < ApplicationJob
  queue_as :low_priority_maintenance

  # One concurrent sync per repository — overlapping merge-upstream calls on
  # the same fork are pointless and can race.
  limits_concurrency to: 1, key: ->(repository_id, *) { "sync_fork:#{repository_id}" }

  def perform(repository_id)
    repository = Repository.find_by(id: repository_id)
    return unless repository&.fork_syncable?
    return if repository.archived?

    ForkSyncService.call(repository: repository)
  end
end
