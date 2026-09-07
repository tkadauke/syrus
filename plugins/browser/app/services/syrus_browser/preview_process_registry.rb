module SyrusBrowser
  # In-process registry for background dev-server processes spawned by
  # RuntimeSessionProvider#start_session, keyed by RuntimeSession
  # workspace_ref. Mirrors Mcp::Tools::AgentPreviewRegistry's shape
  # (register/get/kill/kill_all/reset!) but is intentionally a separate
  # registry: the existing one is keyed by, and scoped to the lifetime of, a
  # workflow Run, while a RuntimeSession's dev server can outlive any single
  # MCP tool call.
  module PreviewProcessRegistry
    MUTEX = Mutex.new
    private_constant :MUTEX

    @previews = {} # workspace_ref => { pid: Integer, port: Integer }

    class << self
      def register(session_key:, pid:, port:)
        MUTEX.synchronize { @previews[session_key] = { pid: pid, port: port } }
      end

      def get(session_key)
        MUTEX.synchronize { @previews[session_key]&.dup }
      end

      def kill(session_key)
        preview = MUTEX.synchronize { @previews.delete(session_key) }
        kill_pgroup(preview[:pid]) if preview
      end

      def kill_all
        MUTEX.synchronize do
          @previews.each_value { |p| kill_pgroup(p[:pid]) }
          @previews.clear
        end
      end

      def reset!
        MUTEX.synchronize { @previews.clear }
      end

      private

      def kill_pgroup(pid)
        Process.kill("-TERM", pid)
      rescue Errno::ESRCH, Errno::EPERM
        # Already gone.
      end
    end
  end
end
