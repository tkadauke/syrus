module SyrusMcp
  # In-process registry for background preview processes spawned by the
  # start_preview MCP tool. Lives entirely in sidecar process memory:
  # one registry per step execution, automatically cleared when the
  # sidecar exits (via the at_exit hook registered in Sidecar#run).
  module AgentPreviewRegistry
    MUTEX = Mutex.new
    private_constant :MUTEX

    @previews = {}  # run_id → { pid: Integer, port: Integer }

    class << self
      def register(run_id:, pid:, port:)
        MUTEX.synchronize { @previews[run_id] = { pid: pid, port: port } }
      end

      def get(run_id)
        MUTEX.synchronize { @previews[run_id]&.dup }
      end

      def kill(run_id)
        preview = MUTEX.synchronize { @previews.delete(run_id) }
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
