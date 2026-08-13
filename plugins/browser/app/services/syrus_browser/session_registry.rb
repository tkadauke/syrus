module SyrusBrowser
  # In-process registry of live browser Sessions, one per Run. Lives entirely
  # in sidecar process memory — mirrors Mcp::Tools::AgentPreviewRegistry's
  # per-step lifecycle. The sidecar's at_exit hook (app/services/mcp/sidecar.rb)
  # kills every remaining session so a step that never calls browser_close
  # still doesn't leak a headless Chromium process past the step's lifetime.
  module SessionRegistry
    MUTEX = Mutex.new
    private_constant :MUTEX

    @sessions = {}
    @session_factory = ->(run_id) { Session.spawn(run_id) }

    class << self
      # Test seam: swap in a fake factory so specs never spawn a real
      # @playwright/mcp subprocess.
      attr_accessor :session_factory

      def fetch(run_id)
        MUTEX.synchronize { @sessions[run_id] ||= session_factory.call(run_id) }
      end

      def kill(run_id)
        session = MUTEX.synchronize { @sessions.delete(run_id) }
        session&.close
      end

      def kill_all
        sessions = MUTEX.synchronize { @sessions.dup.tap { @sessions.clear } }
        sessions.each_value(&:close)
      end

      def reset!
        MUTEX.synchronize { @sessions.clear }
        self.session_factory = ->(run_id) { Session.spawn(run_id) }
      end
    end
  end
end
