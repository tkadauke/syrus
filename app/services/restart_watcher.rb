# Watches Rails.cache for a per-role "poison pill" restart timestamp and
# gracefully terminates this process when one appears. Written by
# Admin::RestartService via the admin Restart action; read here so the
# mechanism works identically under Kubernetes, Docker Compose, and local
# dev with no environment-specific restart code.
#
# Same operational pattern as InstanceVersionSupervisor: a single
# daemon thread lazily started by an initializer, gated on
# SyrusVersion.server_process? so it never runs in the console, test
# suite, or asset compilation.
class RestartWatcher
  TICK_INTERVAL_SECONDS = 10
  MAX_JITTER_SECONDS = 20

  class << self
    def ensure_running
      return if disabled?

      @mutex ||= Mutex.new
      @mutex.synchronize do
        @started_at ||= Time.now.utc.to_f
        return if @thread&.alive?
        @thread = spawn_thread
      end
    end

    # Test seam.
    def reset_for_tests!
      @mutex&.synchronize do
        @thread&.kill
        @thread = nil
      end
      @started_at = nil
    end

    # The moment this process started watching. Restart timestamps
    # older than this belong to a restart this process already
    # satisfied (or predates it) and are ignored — prevents a restart
    # loop where the newly booted process immediately kills itself.
    def started_at
      @started_at ||= Time.now.utc.to_f
    end

    # Public for tests — runs one check without sleeping in a loop.
    # Returns true if a restart was actually triggered.
    def tick
      restart_at = Rails.cache.read(cache_key)
      return false unless restart_at.to_f > started_at

      jitter = rand(0..MAX_JITTER_SECONDS)
      Rails.logger.info("[RestartWatcher] Restart requested (role=#{SyrusVersion.role}). Shutting down in #{jitter}s.")
      sleep(jitter)
      Process.kill("TERM", Process.pid)
      true
    rescue StandardError => e
      Rails.logger.warn("[RestartWatcher] #{e.message}")
      false
    end

    private

    def disabled?
      Rails.env.test? || !SyrusVersion.server_process?
    end

    def cache_key
      "syrus:restart_#{SyrusVersion.role}"
    end

    def spawn_thread
      Thread.new do
        Thread.current.name = "restart-watcher"
        loop do
          sleep TICK_INTERVAL_SECONDS
          tick
        end
      end.tap { |t| t.abort_on_exception = false }
    end
  end
end
