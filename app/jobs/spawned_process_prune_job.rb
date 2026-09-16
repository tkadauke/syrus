# Daily sweep for the SpawnedProcess audit table — drops finalized
# rows past the configured retention window so the table doesn't grow
# without bound. Active rows (finished_at IS NULL) are left for the
# reaper to finalize on the next ReapOrphanedSpawnedProcessesJob tick.
class SpawnedProcessPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  BATCH_SIZE = 1_000

  def perform
    deleted = 0

    SpawnedProcess.prunable.in_batches(of: BATCH_SIZE) do |batch|
      # `command_spans.spawned_process_id` carries a real foreign key. The
      # `dependent: :nullify` on the association does not help here because
      # delete_all skips callbacks, so the raw delete used to abort the whole
      # sweep with ActiveRecord::InvalidForeignKey and the table grew without
      # bound. Detach the spans first, matching what :nullify would have done.
      CommandSpan.where(spawned_process_id: batch.ids).update_all(spawned_process_id: nil)
      deleted += batch.delete_all
    end

    Rails.logger.info("[SpawnedProcessPruneJob] deleted #{deleted} finished rows") if deleted > 0
  end
end
