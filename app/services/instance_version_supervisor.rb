require "socket"

# Registers the running process in instance_versions on boot,
# heartbeats every TICK_INTERVAL_SECONDS, finalizes on shutdown via
# at_exit. One supervisor per Rails process — mutex-guarded
# memoization makes ensure_running idempotent across multiple Puma
# worker forks or other concurrent first-callers.
#
# Same operational pattern as SpawnedProcessSupervisor: conditional
# update_all so heartbeats race safely with the recurring reaper,
# disabled in test env, daemon thread killed on process exit.
class InstanceVersionSupervisor
  TICK_INTERVAL_SECONDS = 30

  class << self
    def ensure_running
      return if disabled?

      @mutex ||= Mutex.new
      @mutex.synchronize do
        @instance ||= register_instance_safely
        return if @thread&.alive?
        @thread = spawn_heartbeat_thread
        @at_exit_registered ||= install_at_exit_hook
      end
    end

    # Test seam.
    def reset_for_tests!
      @mutex&.synchronize do
        @thread&.kill
        @thread = nil
        @instance = nil
        @at_exit_registered = false
      end
    end

    # Public for tests. Bumps last_heartbeat_at on the instance row,
    # creating it if it was reaped between registration and now.
    def heartbeat(instance = @instance, now: Time.current)
      unless instance
        @instance = register_instance_safely(now: now)
        return
      end

      data_root_snapshot = data_root_usage_snapshot
      attrs = { last_heartbeat_at: now }.merge(data_root_usage_attrs(data_root_snapshot))
      rows = InstanceVersion.where(id: instance.id, finished_at: nil)
                            .update_all(attrs)
      record_worker_host_health_sample(instance, observed_at: now, data_root_snapshot: data_root_snapshot) if rows == 1
      return if rows == 1

      # Reaper finalized us between heartbeats — re-register a fresh
      # row so the table reflects current reality.
      @instance = register_instance_safely(now: now)
    end

    # Public for tests. Stamps finished_at; idempotent.
    def finalize(instance = @instance, outcome: "shutdown", now: Time.current)
      return unless instance

      InstanceVersion.where(id: instance.id, finished_at: nil)
                     .update_all(finished_at: now, outcome: outcome)
    end

    private

    def disabled?
      Rails.env.test? || !SyrusVersion.server_process?
    end

    # Worker pods measure their own SYRUS_DATA_ROOT usage each heartbeat so the
    # disk-health banner is per-pod under local-disk multi-worker. Web pods
    # don't mount the workspace volume, so they report nothing. `df` is cheap
    # (unlike `du`); failures are swallowed so a heartbeat never breaks.
    def data_root_usage_attrs(snapshot)
      return {} unless snapshot
      {
        data_root_used_percent: snapshot.used_percent,
        data_root_available_bytes: snapshot.available_bytes,
        data_root_total_bytes: snapshot.total_bytes,
        data_root_path: snapshot.path
      }
    end

    def data_root_usage_snapshot
      return nil unless SyrusVersion.role == "worker"

      DataRootDiskUsage.read(WorkflowWorkspace.data_root.to_s)
    rescue StandardError => e
      Rails.logger.warn("[InstanceVersionSupervisor] data-root measure failed: #{e.class}: #{e.message}")
      nil
    end

    def register_instance_safely(now: Time.current)
      register_instance!(now: now)
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked => e
      Rails.logger.warn("[InstanceVersionSupervisor] registration skipped: #{e.class}: #{e.message}")
      nil
    end

    # Insert or refresh the (hostname, role) row. If a stale row exists
    # for this pod (e.g. the previous Rails process crashed), we treat
    # the current process as the live owner — overwrite the row's
    # version + started_at + clear finished_at — and return it.
    def register_instance!(now: Time.current)
      hostname = SyrusVersion.hostname
      role = SyrusVersion.role
      version = SyrusVersion.current

      existing = InstanceVersion.find_by(hostname: hostname, role: role)
      if existing
        existing.update!(
          version: version,
          started_at: now,
          last_heartbeat_at: now,
          finished_at: nil,
          outcome: nil
        )
        return existing
      end

      InstanceVersion.create!(
        hostname: hostname,
        role: role,
        version: version,
        started_at: now,
        last_heartbeat_at: now
      )
    rescue ActiveRecord::RecordNotUnique
      # Another Puma worker fork beat us to the insert; pick up the
      # row they created and let them own the heartbeat.
      InstanceVersion.find_by(hostname: SyrusVersion.hostname, role: SyrusVersion.role)
    end

    def spawn_heartbeat_thread
      Thread.new do
        Thread.current.name = "instance-version-supervisor"
        Rails.logger.info("[InstanceVersionSupervisor] heartbeating as #{@instance&.role}/#{@instance&.hostname} version=#{@instance&.version}")
        loop do
          sleep TICK_INTERVAL_SECONDS
          run_tick_safely
        end
      end
    end

    def run_tick_safely
      ActiveRecord::Base.connection_pool.with_connection { heartbeat }
    rescue StandardError => e
      Rails.logger.warn("[InstanceVersionSupervisor] heartbeat raised: #{e.class}: #{e.message}")
    end

    def record_worker_host_health_sample(instance, observed_at:, data_root_snapshot:)
      return unless instance.role == "worker"

      WorkerHostHealthSampler.record!(instance: instance, observed_at: observed_at, data_root_snapshot: data_root_snapshot)
    rescue StandardError => e
      Rails.logger.warn("[InstanceVersionSupervisor] worker host health sample failed: #{e.class}: #{e.message}")
    end

    # SIGTERM via at_exit lets us flag the row as gracefully finished.
    # SIGKILL bypasses this — the reaper handles those.
    def install_at_exit_hook
      at_exit do
        begin
          ActiveRecord::Base.connection_pool.with_connection { finalize }
        rescue StandardError => e
          Rails.logger.warn("[InstanceVersionSupervisor] at_exit finalize failed: #{e.class}: #{e.message}")
        end
      end
      true
    end
  end
end
