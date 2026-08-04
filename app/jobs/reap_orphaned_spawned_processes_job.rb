# Cross-hostname SpawnedProcess sweep. Catches the "pod is gone"
# failure mode that the in-process SpawnedProcessSupervisor on the
# *new* pod can't see (the dead pod owned those rows, and the new
# pod has a different hostname). Uses SolidQueue::Process as the
# authoritative "this hostname has a live worker" signal — same one
# bin/healthcheck uses.
#
# Detection time: ~SQ process_alive_threshold (5 min) + job
# interval (1 min) after pod death.
#
# Layer 2 (the in-process supervisor) handles same-hostname pid death
# at 30s resolution; this job only deals with hostnames that have
# disappeared from SQ::Process entirely.
class ReapOrphanedSpawnedProcessesJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    live_hosts = live_solid_queue_hostnames
    reap_cross_host_orphans(live_hosts) if live_hosts # SQ unreachable — single-DB dev/test
    reap_stale_chat_turns
  end

  private

  def reap_cross_host_orphans(live_hosts)
    SpawnedProcess.running
                  .where.not(hostname: live_hosts.to_a)
                  .find_each do |sp|
      finished_at = Time.current
      rows = SpawnedProcess.where(id: sp.id, finished_at: nil)
                           .update_all(finished_at: finished_at, outcome: "orphaned")
      next if rows.zero?

      Rails.logger.info("[ReapOrphanedSpawnedProcessesJob] finalized SpawnedProcess ##{sp.id} on dead host #{sp.hostname} (pid #{sp.pid}, kind #{sp.kind})")
      ChatStopReconciler.reconcile_spawned_process!(sp, finished_at: finished_at)
    end
  end

  def reap_stale_chat_turns
    reconciled = ChatStopReconciler.reconcile_stale_turns!
    return unless reconciled.positive?

    Rails.logger.info("[ReapOrphanedSpawnedProcessesJob] reconciled #{reconciled} stale chat turn(s)")
  end

  def live_solid_queue_hostnames
    SolidQueue::Process.distinct.pluck(:hostname).to_set
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.debug("[ReapOrphanedSpawnedProcessesJob] SQ tables unreachable (#{e.class}); skipping cross-host sweep")
    nil
  end
end
