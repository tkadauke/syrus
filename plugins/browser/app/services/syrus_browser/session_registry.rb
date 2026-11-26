module SyrusBrowser
  # In-process registry of live browser Sessions, one per owning session key
  # (see SessionContext -- a workflow Run for visual_review, or a Coding
  # Mode chat's RuntimeSession). Lives entirely in sidecar process memory —
  # mirrors Mcp::Tools::AgentPreviewRegistry's per-step lifecycle. The
  # sidecar's at_exit hook (app/services/mcp/sidecar.rb) kills every
  # remaining session so a step that never calls browser_close still
  # doesn't leak a headless Chromium process past the step's lifetime.
  module SessionRegistry
    MUTEX = Mutex.new
    private_constant :MUTEX

    @sessions = {}
    @session_factory = ->(session_key) { Session.spawn(session_key) }

    class << self
      # Test seam: swap in a fake factory so specs never spawn a real
      # @playwright/mcp subprocess.
      attr_accessor :session_factory

      def fetch(session_key)
        MUTEX.synchronize { @sessions[session_key] ||= session_factory.call(session_key) }
      end

      def kill(session_key)
        session = MUTEX.synchronize { @sessions.delete(session_key) }
        session&.close
      end

      def kill_all
        sessions = MUTEX.synchronize { @sessions.dup.tap { @sessions.clear } }
        sessions.each_value(&:close)
      end

      def reset!
        MUTEX.synchronize { @sessions.clear }
        self.session_factory = ->(session_key) { Session.spawn(session_key) }
      end
    end
  end
end
