module Mcp::Tools
  # In-process registry for background preview processes spawned via
  # PreviewProcessLauncher, keyed by an arbitrary caller-supplied identifier
  # (a workflow Run id for the start_preview MCP tool; a RuntimeSession's
  # workspace_ref for SyrusBrowser::RuntimeSessionProvider). Lives entirely
  # in sidecar process memory: one registry per step execution, automatically
  # cleared when the sidecar exits (via the at_exit hook registered in
  # Sidecar#run).
  module AgentPreviewRegistry
    MUTEX = Mutex.new
    private_constant :MUTEX

    @previews = {}  # key → { pid: Integer, port: Integer }

    class << self
      def register(key:, pid:, port:)
        MUTEX.synchronize { @previews[key] = { pid: pid, port: port } }
      end

      def get(key)
        MUTEX.synchronize { @previews[key]&.dup }
      end

      def kill(key)
        preview = MUTEX.synchronize { @previews.delete(key) }
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
