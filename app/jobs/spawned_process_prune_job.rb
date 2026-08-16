# Daily sweep for the SpawnedProcess audit table — drops finalized
# rows older than RETAIN_AFTER_FINISHED so the table doesn't grow
# without bound. Active rows (finished_at IS NULL) are left for the
# reaper to finalize on the next ReapOrphanedSpawnedProcessesJob tick.
class SpawnedProcessPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  RETAIN_AFTER_FINISHED = 7.days
  BATCH_SIZE = 1_000

  def perform
    cutoff = RETAIN_AFTER_FINISHED.ago
    deleted = 0

    SpawnedProcess.finished.where("finished_at < ?", cutoff).in_batches(of: BATCH_SIZE) do |batch|
      # `command_spans.spawned_process_id` carries a real foreign key. The
      # `dependent: :nullify` on the association does not help here because
      # delete_all skips callbacks, so the raw delete used to abort the whole
      # sweep with ActiveRecord::InvalidForeignKey and the table grew without
      # bound. Detach the spans first, matching what :nullify would have done.
      CommandSpan.where(spawned_process_id: batch.ids).update_all(spawned_process_id: nil)
      deleted += batch.delete_all
    end

    Rails.logger.info("[SpawnedProcessPruneJob] deleted #{deleted} finished rows older than #{cutoff.iso8601}") if deleted > 0
  end
end
