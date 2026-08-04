# Daily sweep for the SpawnedProcess audit table — drops finalized
# rows older than RETAIN_AFTER_FINISHED so the table doesn't grow
# without bound. Active rows (finished_at IS NULL) are left for the
# reaper to finalize on the next ReapOrphanedSpawnedProcessesJob tick.
class SpawnedProcessPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  RETAIN_AFTER_FINISHED = 7.days

  def perform
    cutoff = RETAIN_AFTER_FINISHED.ago
    deleted = SpawnedProcess.finished.where("finished_at < ?", cutoff).delete_all
    Rails.logger.info("[SpawnedProcessPruneJob] deleted #{deleted} finished rows older than #{cutoff.iso8601}") if deleted > 0
  end
end
