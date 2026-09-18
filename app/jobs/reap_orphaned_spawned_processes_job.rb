# SpawnedProcess sweep. Catches failure modes that the in-process
# SpawnedProcessSupervisor can miss after worker restarts: pidless rows, rows
# whose host disappeared, and rows left behind by an older worker process on a
# hostname that has since restarted.
#
# Detection time: ~SQ process_alive_threshold (5 min) + job
# interval (1 min) after pod death.
#
class ReapOrphanedSpawnedProcessesJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    live_hosts = live_process_hostnames
    reap_pidless_processes
    reap_rows_from_previous_worker_instances
    reap_cross_host_orphans(live_hosts) if live_hosts # SQ unreachable — single-DB dev/test
    reap_crashed_chat_turns
    reap_stale_chat_turns
  end

  private

  def reap_crashed_chat_turns
    reconciled = ChatTurnAutoRetryReconciler.sweep!
    return unless reconciled.positive?

    Rails.logger.info("[ReapOrphanedSpawnedProcessesJob] reconciled #{reconciled} crashed chat turn auto-retry item(s)")
  end

  def reap_pidless_processes
    SpawnedProcess.pidless_running.find_each do |sp|
      finished_at = Time.current
      rows = SpawnedProcess.where(id: sp.id, finished_at: nil, pid: nil)
                           .update_all(finished_at: finished_at, outcome: "orphaned")
      next if rows.zero?

      Rails.logger.info("[ReapOrphanedSpawnedProcessesJob] finalized pidless SpawnedProcess ##{sp.id} on #{sp.hostname} (kind #{sp.kind})")
      reconcile_finalized_spawned_process!(sp, finished_at: finished_at)
    end
  end

  def reap_cross_host_orphans(live_hosts)
    SpawnedProcess.running
                  .where.not(hostname: live_hosts.to_a)
                  .find_each do |sp|
      finished_at = Time.current
      rows = SpawnedProcess.where(id: sp.id, finished_at: nil)
                           .update_all(finished_at: finished_at, outcome: "orphaned")
      next if rows.zero?

      Rails.logger.info("[ReapOrphanedSpawnedProcessesJob] finalized SpawnedProcess ##{sp.id} on dead host #{sp.hostname} (pid #{sp.pid}, kind #{sp.kind})")
      reconcile_finalized_spawned_process!(sp, finished_at: finished_at)
    end
  end

  def reap_rows_from_previous_worker_instances
    fresh_worker_starts_by_host.each do |hostname, started_at|
      SpawnedProcess.running
                    .where(hostname: hostname)
                    .where("started_at < ?", started_at)
                    .find_each do |sp|
        finalize_orphaned_process!(sp, reason: "worker instance restarted")
      end
    end
  end

  def reap_stale_chat_turns
    reconciled = ChatStopReconciler.reconcile_stale_turns!
    return unless reconciled.positive?

    Rails.logger.info("[ReapOrphanedSpawnedProcessesJob] reconciled #{reconciled} stale chat turn(s)")
  end

  def live_process_hostnames
    sources = [ live_solid_queue_hostnames, live_instance_version_hostnames ].compact
    return nil if sources.empty?

    sources.reduce(Set.new, :+)
  end

  def live_solid_queue_hostnames
    SolidQueue::Process.distinct.pluck(:hostname).to_set
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.debug("[ReapOrphanedSpawnedProcessesJob] SQ tables unreachable (#{e.class}); skipping cross-host sweep")
    nil
  end

  def live_instance_version_hostnames
    InstanceVersion.fresh.distinct.pluck(:hostname).to_set
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.debug("[ReapOrphanedSpawnedProcessesJob] instance_versions unreachable (#{e.class}); skipping instance-version host sweep")
    nil
  end

  def fresh_worker_starts_by_host
    InstanceVersion.fresh
                   .where(role: "worker")
                   .group(:hostname)
                   .maximum(:started_at)
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.debug("[ReapOrphanedSpawnedProcessesJob] instance_versions unreachable (#{e.class}); skipping restarted-worker sweep")
    {}
  end

  def finalize_orphaned_process!(sp, reason:)
    finished_at = Time.current
    rows = SpawnedProcess.where(id: sp.id, finished_at: nil)
                         .update_all(finished_at: finished_at, outcome: "orphaned")
    return if rows.zero?

    Rails.logger.info("[ReapOrphanedSpawnedProcessesJob] finalized SpawnedProcess ##{sp.id} on #{sp.hostname} (pid #{sp.pid}, kind #{sp.kind}) — #{reason}")
    reconcile_finalized_spawned_process!(sp, finished_at: finished_at)
  end

  def reconcile_finalized_spawned_process!(sp, finished_at:)
    return if ChatTurnAutoRetryReconciler.reconcile_spawned_process!(sp, finished_at: finished_at)

    ChatStopReconciler.reconcile_spawned_process!(sp, finished_at: finished_at)
  end
end
