module Timeline
  # Read-only micro (single-Workflow waterfall) query backing the
  # worker-activity-timeline plugin's drill-down view: ordered Steps with
  # their Runs. Step/Run carry no host column of their own, so every row
  # is attributed to the parent Workflow's single (hostname, pid) via
  # WorkerAttribution -- the same resolver Timeline::MacroQuery uses.
  class WorkflowWaterfallQuery
    def self.call(workflow_id:) = new(workflow_id: workflow_id).call

    def initialize(workflow_id:)
      @workflow = Workflow.includes(steps: :runs).find(workflow_id)
    end

    def call
      {
        workflow: workflow_payload,
        steps: steps.map { |step| step_payload(step) }
      }
    end

    private

    attr_reader :workflow

    def attribution
      @attribution ||= WorkerAttribution.for_workflows([ workflow ]).fetch(workflow.id)
    end

    def steps
      @steps ||= workflow.steps.to_a
    end

    def workflow_payload
      {
        id: workflow.id,
        job_id: workflow.job_id,
        trigger_kind: workflow.trigger_kind,
        status: workflow.state,
        started_at: workflow.started_at&.iso8601,
        finished_at: workflow.finished_at&.iso8601,
        hostname: attribution[:hostname],
        pid: attribution[:pid]
      }
    end

    def step_payload(step)
      {
        id: step.id,
        kind: step.kind,
        status: step.state,
        position: step.position,
        iteration: step.iteration,
        started_at: step.started_at&.iso8601,
        finished_at: step.finished_at&.iso8601,
        hostname: attribution[:hostname],
        pid: attribution[:pid],
        runs: step.runs.map { |run| run_payload(run) }
      }
    end

    def run_payload(run)
      {
        id: run.id,
        status: run.state,
        iteration: run.iteration,
        started_at: run.started_at&.iso8601,
        finished_at: run.finished_at&.iso8601,
        last_heartbeat_at: run.last_heartbeat_at&.iso8601
      }
    end
  end
end
