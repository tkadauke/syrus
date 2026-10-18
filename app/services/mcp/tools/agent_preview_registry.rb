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
    @launch_mutexes = Hash.new { |hash, key| hash[key] = Mutex.new }

    class << self
      def register(key:, pid:, port:, cleanup: nil)
        MUTEX.synchronize { @previews[key] = { pid: pid, port: port, cleanup: cleanup }.compact }
      end

      def get(key)
        MUTEX.synchronize { @previews[key]&.slice(:pid, :port) }
      end

      def synchronize_launch(key, &block)
        launch_mutex = MUTEX.synchronize { @launch_mutexes[key] }
        launch_mutex.synchronize(&block)
      end

      def kill(key)
        preview = MUTEX.synchronize { @previews.delete(key) }
        stop_preview(preview) if preview
      end

      def kill_prefix(prefix)
        previews = MUTEX.synchronize do
          matches = @previews.select { |key, _| key.to_s.start_with?(prefix.to_s) }
          matches.each_key { |key| @previews.delete(key) }
          matches.values
        end
        previews.each { |preview| stop_preview(preview) }
      end

      def kill_all
        previews = MUTEX.synchronize do
          values = @previews.values
          @previews.clear
          values
        end
        previews.each { |preview| stop_preview(preview) }
      end

      def reset!
        MUTEX.synchronize do
          @previews.clear
          @launch_mutexes.clear
        end
      end

      private

      def kill_pgroup(pid)
        Process.kill("-TERM", pid)
      rescue Errno::ESRCH, Errno::EPERM
        # Already gone.
      end

      def stop_preview(preview)
        kill_pgroup(preview[:pid])
        preview[:cleanup]&.call
      end
    end
  end
end
