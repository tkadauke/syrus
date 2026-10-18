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

    @previews = {}  # key → { pid: Integer, port: Integer, spawned_process_id: Integer }
    @launch_mutexes = Hash.new { |hash, key| hash[key] = Mutex.new }

    class << self
      def register(key:, pid:, port:, spawned_process_id: nil)
        MUTEX.synchronize do
          @previews[key] = { pid: pid, port: port, spawned_process_id: spawned_process_id }.compact
        end
      end

      def get(key)
        MUTEX.synchronize { @previews[key]&.dup }
      end

      def synchronize_launch(key, &block)
        launch_mutex = MUTEX.synchronize { @launch_mutexes[key] }
        launch_mutex.synchronize(&block)
      end

      def kill(key)
        preview = MUTEX.synchronize { @previews.delete(key) }
        cancel(preview) if preview
      end

      def kill_prefix(prefix)
        previews = MUTEX.synchronize do
          matches = @previews.select { |key, _| key.to_s.start_with?(prefix.to_s) }
          matches.each_key { |key| @previews.delete(key) }
          matches.values
        end
        previews.each { |preview| cancel(preview) }
      end

      def kill_all
        previews = MUTEX.synchronize do
          values = @previews.values
          @previews.clear
          values
        end
        handles = previews.filter_map { |preview| managed_handle(preview) }
        handles.each(&:cancel!)
        handles.each { |handle| await_cancellation(handle) }
      end

      def reset!
        MUTEX.synchronize do
          @previews.clear
          @launch_mutexes.clear
        end
      end

      private

      def cancel(preview)
        handle = managed_handle(preview)
        return unless handle

        handle.cancel!
        await_cancellation(handle)
      rescue ActiveRecord::RecordNotFound
        # The durable process record was already pruned.
      end

      def managed_handle(preview)
        return unless preview[:spawned_process_id]

        ProcessRunner::BackgroundHandle.find(preview[:spawned_process_id])
      end

      def await_cancellation(handle)
        handle.finalize(timeout: ProcessRunner::KILL_POLL_INTERVAL_SECONDS + ProcessRunner::TERM_GRACE_SECONDS + 1)
      end
    end
  end
end
