module WorkUnits
  class WorkflowCancellation
    def self.cancel!(workflow, reason:, artifacts: {}, by_work_unit: nil)
      new(workflow, reason: reason, artifacts: artifacts, by_work_unit: by_work_unit).cancel!
    end

    # Cancels every queued (not yet started) retry-workflow-attempt Workflow
    # for a Job. Scoped to `WorkDefinitions.retry_workflow_attempt_kinds`
    # (currently `retry` and `checkpoint_resume`) rather than the bare
    # `"retry"` WorkUnit kind, because `RetryWorkflowEnqueuer` tries
    # `RunCheckpointResume` first and only falls back to a plain `retry`
    # Workflow when no safe checkpoint resume is available -- a queued
    # `checkpoint_resume` Workflow is just as stale once the Job no longer
    # needs a fresh retry, and missing it here would leave it free to fire
    # later against a branch/approval state the caller just settled.
    def self.cancel_queued_retry_workflows_for_job!(job:, reason:)
      retry_workflow_ids = WorkUnits::Ownership.active_workflow_ids(
        [ job.id ], kinds: WorkDefinitions.retry_workflow_attempt_kinds, states: [ "queued" ]
      ).to_a
      return if retry_workflow_ids.empty?

      job.workflows.where(id: retry_workflow_ids).find_each do |candidate|
        candidate.artifacts = (candidate.artifacts || {}).merge(
          "retry_cancelled_reason" => reason,
          "retry_cancelled_at" => Time.current.iso8601
        )
        cancel!(candidate, reason: reason, artifacts: candidate.artifacts)
      end
    end

    def initialize(workflow, reason:, artifacts:, by_work_unit:)
      @workflow = workflow
      @reason = reason.to_s
      @artifacts = artifacts || {}
      @by_work_unit = by_work_unit
    end

    def cancel!
      workflow.artifacts = workflow.artifacts.to_h.merge(artifacts)
      workflow.cancel! if workflow.may_cancel?
      workflow.save!
      workflow.work_unit&.preempt!(reason: reason, by_work_unit: by_work_unit)
      workflow
    end

    private

    attr_reader :workflow, :reason, :artifacts, :by_work_unit
  end
end
