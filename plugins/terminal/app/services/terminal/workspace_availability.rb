module Terminal
  class WorkspaceAvailability
    Result = Data.define(:available, :reason, :working_directory, :queue_name) do
      def available? = available

      def as_json(*)
        {
          available: available?,
          reason: reason,
          working_directory: working_directory,
          queue_name: queue_name
        }.compact
      end
    end

    CLEANED_UP_REASON = "This workflow workspace has been cleaned up.".freeze
    MISSING_PATH_REASON = "This workflow workspace is not present on this storage root.".freeze
    DEAD_STORAGE_REASON = "This workflow workspace is on a worker storage root that is not currently reachable.".freeze
    DEAD_WORKER_REASON = "This workflow workspace is on a worker that is not currently reachable.".freeze

    def self.for(workflow) = new(workflow).result

    def self.by_workflow_id(workflows)
      workflows.to_h { |workflow| [ workflow.id, Terminal::WorkspaceAvailability.for(workflow).as_json ] }
    end

    def initialize(workflow)
      @workflow = workflow
    end

    def result
      path = WorkflowWorkspace.path_for(workflow).to_s
      return unavailable(CLEANED_UP_REASON, path) if workflow.cleaned_up_at.present?
      return storage_key_result(path) if workflow.worker_storage_key.present?
      return hostname_result(path) if workflow.worker_hostname.present?
      return available(path) if File.directory?(path)

      unavailable(MISSING_PATH_REASON, path)
    end

    private

    attr_reader :workflow

    def storage_key_result(path)
      storage_key = workflow.worker_storage_key
      queue = Workflow.resume_queue_name(storage_key)
      return unavailable(DEAD_STORAGE_REASON, path) unless InstanceVersion.worker_queue_live?(queue)
      return available(path, queue_name: queue) if storage_key != WorkerStorageIdentity.queue_key
      return available(path, queue_name: queue) if File.directory?(path)

      unavailable(MISSING_PATH_REASON, path)
    end

    def hostname_result(path)
      hostname = workflow.worker_hostname
      remote = hostname != SyrusVersion.hostname
      return unavailable(DEAD_WORKER_REASON, path) if remote && !InstanceVersion.worker_live?(hostname)
      return available(path, queue_name: Workflow.resume_queue_name(hostname)) if remote
      return available(path) if File.directory?(path)

      unavailable(MISSING_PATH_REASON, path)
    end

    def available(path, queue_name: nil)
      Result.new(available: true, reason: nil, working_directory: path, queue_name: queue_name)
    end

    def unavailable(reason, path)
      Result.new(available: false, reason: reason, working_directory: path, queue_name: nil)
    end
  end
end
