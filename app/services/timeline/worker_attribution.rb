module Timeline
  # Resolves the worker identity that ran each given
  # Workflow, in a single fallback chain shared by Timeline::MacroQuery
  # (many workflows at once) and Timeline::WorkflowWaterfallQuery (one
  # workflow): the earliest WorkflowActivityEvent tied to the workflow is
  # the primary source (it carries queue_role and the actual Process.pid
  # recorded at the moment of the state transition); a SpawnedProcess row is
  # the fallback once WorkflowActivityEvent's 14-day retention has expired;
  # and Workflow#worker_hostname (hostname only, no pid) is the last resort.
  # Workflow#worker_storage_key is kept separately because it is workflow
  # state, not point-in-time event/process state.
  class WorkerAttribution
    def self.for_workflows(workflows) = new(workflows).call

    def initialize(workflows)
      @workflows = Array(workflows)
    end

    def call
      workflows.index_by(&:id).transform_values { |workflow| attribution_for(workflow) }
    end

    private

    attr_reader :workflows

    def attribution_for(workflow)
      event = activity_event_by_workflow[workflow.id]
      process = spawned_process_by_workflow[workflow.id]
      if event
        attribution_hash(workflow: workflow, hostname: event.hostname, pid: event.pid, queue_role: event.queue_role)
      elsif process
        attribution_hash(workflow: workflow, hostname: process.hostname, pid: process.pid)
      elsif workflow.worker_hostname.present?
        attribution_hash(workflow: workflow, hostname: workflow.worker_hostname, pid: nil)
      else
        attribution_hash(workflow: workflow, hostname: nil, pid: nil)
      end
    end

    def attribution_hash(workflow:, hostname:, pid:, queue_role: nil)
      {
        worker_storage_key: workflow.worker_storage_key,
        queue_role: queue_role,
        hostname: hostname,
        pid: pid
      }
    end

    def activity_event_by_workflow
      @activity_event_by_workflow ||= WorkflowActivityEvent
        .where(workflow_id: workflow_ids, event_type: %w[workflow_started run_started])
        .where.not(hostname: nil)
        .order(:occurred_at, :id)
        .group_by(&:workflow_id)
        .transform_values(&:first)
    end

    def spawned_process_by_workflow
      @spawned_process_by_workflow ||= SpawnedProcess
        .where(workflow_id: workflow_ids)
        .where.not(hostname: nil)
        .order(:started_at, :id)
        .group_by(&:workflow_id)
        .transform_values(&:first)
    end

    def workflow_ids
      @workflow_ids ||= workflows.map(&:id)
    end
  end
end
