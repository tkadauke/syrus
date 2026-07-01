require "socket"

# In-process ticker that finalizes own-hostname SpawnedProcess rows
# whose pid is gone. Pairs with ReapOrphanedSpawnedProcessesJob, which
# handles the cross-hostname case (dead pod) — this one handles the
# local case (pid died inside an alive pod without ProcessRunner's
# ensure block running, e.g. Ruby thread crash, OOM-killer on the
# subprocess).
#
# Lifecycle:
#   - First ProcessRunner.new call lazy-starts the supervisor thread.
#     A web pod that never spawns subprocesses never starts a thread.
#   - Thread runs `tick` every TICK_INTERVAL_SECONDS, hostname-scoped.
#   - `tick` skips rows with pid=nil (worker is mid-spawn, can't probe
#     yet) and uses a conditional UPDATE so it races safely with
#     ProcessRunner's own finalize call (whichever lands first wins).
class SpawnedProcessSupervisor
  TICK_INTERVAL_SECONDS = 30

  class << self
    # Idempotent: returns the existing live thread if one's running,
    # else spawns one. Guarded by a mutex so concurrent first-spawns
    # from multiple worker threads don't create duplicate supervisors.
    def ensure_running
      return if disabled?
      @mutex ||= Mutex.new
      @mutex.synchronize do
        return if @thread&.alive?
        @thread = spawn_thread
      end
    end

    # Synchronous single pass. Public for tests; the thread loop calls
    # it under an explicit connection checkout.
    def tick(hostname: Socket.gethostname, now: Time.current)
      SpawnedProcess.running
        .where(hostname: hostname)
        .where.not(pid: nil)
        .find_each do |sp|
          next if pid_alive?(sp.pid)
          finalize_if_still_running(sp, now: now)
        end
    end

    # Test seam: tear down the memoized thread so the next ensure_running
    # starts fresh.
    def reset_for_tests!
      @mutex&.synchronize do
        @thread&.kill
        @thread = nil
      end
    end

    private

    # Background threads + RSpec tests are a footgun (open transactions
    # rolled back across thread boundaries, etc.). Tests should drive
    # `tick` directly.
    def disabled?
      Rails.env.test?
    end

    def spawn_thread
      Thread.new do
        Thread.current.name = "spawned-process-supervisor"
        Rails.logger.info("[SpawnedProcessSupervisor] starting (interval #{TICK_INTERVAL_SECONDS}s, hostname #{Socket.gethostname})")
        loop do
          sleep TICK_INTERVAL_SECONDS
          run_tick_safely
        end
      end
    end

    def run_tick_safely
      ActiveRecord::Base.connection_pool.with_connection { tick }
    rescue StandardError => e
      Rails.logger.warn("[SpawnedProcessSupervisor] tick raised: #{e.class}: #{e.message}")
    end

    def pid_alive?(pid)
      return false unless pid
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      # Pid exists but we can't signal it (different uid namespace).
      # Doesn't happen in our deployment but err toward "alive" — a
      # false-finalize is worse than a delayed one.
      true
    end

    # Conditional UPDATE: only stamps finished_at if it's still NULL.
    # Races safely with ProcessRunner#finalize_spawned_process! — the
    # other path uses the same pattern, so whichever transaction
    # commits first wins and the loser becomes a no-op.
    def finalize_if_still_running(sp, now:)
      rows = SpawnedProcess.where(id: sp.id, finished_at: nil)
                           .update_all(finished_at: now, outcome: "orphaned")
      return if rows.zero?

      Rails.logger.info("[SpawnedProcessSupervisor] finalized SpawnedProcess ##{sp.id} (pid #{sp.pid}, kind #{sp.kind}) — pid gone")
      ChatStopReconciler.reconcile_spawned_process!(sp, finished_at: now)
    end
  end
end
