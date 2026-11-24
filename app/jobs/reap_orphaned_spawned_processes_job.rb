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

  LOCK_ERRORS = [ ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked ].freeze
  MAX_ATTEMPTS = 3
  BACKOFF_BASE_SECONDS = 0.25

  # Raised after every phase has had its turn when at least one phase or row
  # exhausted its lock-contention retries. An exhausted sweep is a failure, not
  # a successful skip; the next minute's sweep picks the remaining work up.
  class ContentionExhausted < StandardError
    attr_reader :failures

    def initialize(failures)
      @failures = failures
      super("ReapOrphanedSpawnedProcessesJob lock contention exhausted: " +
            failures.map { |f| "#{f[:phase]}(#{f[:scope]}) attempts=#{f[:attempts]} #{f[:error_class]}" }.join("; "))
    end
  end

  def perform
    @failures = []
    live_hosts = live_process_hostnames
    run_phase(:pidless) { reap_pidless_processes }
    run_phase(:previous_worker) { reap_rows_from_previous_worker_instances }
    run_phase(:cross_host) { reap_cross_host_orphans(live_hosts) } if live_hosts # SQ unreachable — single-DB dev/test
    run_phase(:crashed_chat_turns) { reap_crashed_chat_turns }
    run_phase(:stale_chat_turns) { reap_stale_chat_turns }
    raise ContentionExhausted.new(@failures) if @failures.any?
  end

  private

  # Runs a whole phase; a contended phase is recorded and never stops the
  # independent phases after it.
  def run_phase(phase, scope: "phase", &block)
    with_lock_retry(phase, scope: scope, &block)
    true
  rescue *LOCK_ERRORS => e
    record_failure(phase, scope, e)
    false
  end

  # Bounded retry with backoff. Only wraps idempotent operations: conditional
  # updates (the ownership guard) and reconcilers that re-check their own state.
  def with_lock_retry(phase, scope:)
    attempts = 0
    begin
      attempts += 1
      yield
    rescue *LOCK_ERRORS => e
      e.instance_variable_set(:@reaper_attempts, attempts)
      Rails.logger.warn("[ReapOrphanedSpawnedProcessesJob] lock contention in #{phase} (#{scope}) attempt #{attempts}/#{MAX_ATTEMPTS}: #{e.class}: #{e.message.to_s.truncate(300)}")
      raise if attempts >= MAX_ATTEMPTS

      backoff(attempts)
      retry
    end
  end

  def backoff(attempt)
    sleep(BACKOFF_BASE_SECONDS * (2**(attempt - 1)))
  end

  def record_failure(phase, scope, error)
    failure = {
      phase: phase,
      scope: scope,
      attempts: error.instance_variable_get(:@reaper_attempts) || MAX_ATTEMPTS,
      error_class: error.class.name,
      statement: error.message.to_s.truncate(500)
    }
    @failures << failure
    Rails.logger.error("[ReapOrphanedSpawnedProcessesJob] lock contention exhausted #{failure.to_json}")
  end

  # Per-row work: a contended row is recorded and skipped so later rows and
  # phases still get their turn. Rows stay unfinished (conditional update is the
  # guard), so the next sweep retries them.
  def each_row(phase, relation)
    relation.find_each do |sp|
      scope = "spawned_process:#{sp.id}"
      begin
        yield sp, scope
      rescue *LOCK_ERRORS => e
        record_failure(phase, scope, e)
      end
    end
  end

  def reap_crashed_chat_turns
    reconciled = ChatTurnAutoRetryReconciler.sweep!
    return unless reconciled.positive?

    Rails.logger.info("[ReapOrphanedSpawnedProcessesJob] reconciled #{reconciled} crashed chat turn auto-retry item(s)")
  end

  def reap_pidless_processes
    each_row(:pidless, SpawnedProcess.pidless_running) do |sp, scope|
      finished_at = Time.current
      rows = with_lock_retry(:pidless, scope: scope) do
        SpawnedProcess.where(id: sp.id, finished_at: nil, pid: nil)
                      .update_all(finished_at: finished_at, outcome: "orphaned")
      end
      next if rows.zero?

      Rails.logger.info("[ReapOrphanedSpawnedProcessesJob] finalized pidless SpawnedProcess ##{sp.id} on #{sp.hostname} (kind #{sp.kind})")
      reconcile_finalized_spawned_process!(sp, finished_at: finished_at, phase: :pidless, scope: scope)
    end
  end

  def reap_cross_host_orphans(live_hosts)
    each_row(:cross_host, SpawnedProcess.running.where.not(hostname: live_hosts.to_a)) do |sp, scope|
      finished_at = Time.current
      rows = with_lock_retry(:cross_host, scope: scope) do
        SpawnedProcess.where(id: sp.id, finished_at: nil)
                      .update_all(finished_at: finished_at, outcome: "orphaned")
      end
      next if rows.zero?

      Rails.logger.info("[ReapOrphanedSpawnedProcessesJob] finalized SpawnedProcess ##{sp.id} on dead host #{sp.hostname} (pid #{sp.pid}, kind #{sp.kind})")
      reconcile_finalized_spawned_process!(sp, finished_at: finished_at, phase: :cross_host, scope: scope)
    end
  end

  def reap_rows_from_previous_worker_instances
    fresh_worker_starts_by_host.each do |hostname, started_at|
      relation = SpawnedProcess.running.where(hostname: hostname).where("started_at < ?", started_at)
      each_row(:previous_worker, relation) do |sp, scope|
        finalize_orphaned_process!(sp, reason: "worker instance restarted", phase: :previous_worker, scope: scope)
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

  def finalize_orphaned_process!(sp, reason:, phase:, scope:)
    finished_at = Time.current
    rows = with_lock_retry(phase, scope: scope) do
      SpawnedProcess.where(id: sp.id, finished_at: nil)
                    .update_all(finished_at: finished_at, outcome: "orphaned")
    end
    return if rows.zero?

    Rails.logger.info("[ReapOrphanedSpawnedProcessesJob] finalized SpawnedProcess ##{sp.id} on #{sp.hostname} (pid #{sp.pid}, kind #{sp.kind}) — #{reason}")
    reconcile_finalized_spawned_process!(sp, finished_at: finished_at, phase: phase, scope: scope)
  end

  # The row is already finalized by the conditional update (only one reaper can
  # win it), so reconciliation is retried here in isolation; it must not rerun
  # the update or be reachable by a second reaper.
  def reconcile_finalized_spawned_process!(sp, finished_at:, phase:, scope:)
    with_lock_retry(phase, scope: "#{scope}:reconcile") do
      next if ChatTurnAutoRetryReconciler.reconcile_spawned_process!(sp, finished_at: finished_at)

      ChatStopReconciler.reconcile_spawned_process!(sp, finished_at: finished_at)
    end
  end
end
