module WorkUnits
  class WorkflowCancellation
    OPERATOR_STALE_WORK_REASON = "operator_stale_work_repair".freeze

    def self.cancel!(workflow, reason:, artifacts: {}, by_work_unit: nil, cause: nil)
      new(workflow, reason: reason, artifacts: artifacts, by_work_unit: by_work_unit, cause: cause).cancel!
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
        cancel!(
          candidate,
          reason: reason,
          artifacts: {
            "retry_cancelled_reason" => reason,
            "retry_cancelled_at" => Time.current.iso8601
          }
        )
      end
    end

    def initialize(workflow, reason:, artifacts:, by_work_unit:, cause: nil)
      @cause = cause
      @workflow = workflow
      @reason = reason.to_s
      @artifacts = artifacts || {}
      @by_work_unit = by_work_unit
    end

    def cancel!
      # Carry over only what this instance changed relative to the database,
      # not its whole artifact snapshot: writing a stale snapshot back inside
      # the lock would revert keys another writer set after it was loaded.
      staged_changes = workflow.staged_artifact_changes
      workflow.reload if workflow.has_changes_to_save?

      # Cancelling rolls up to the WorkUnit, intent and Job, so the Workflow's
      # ancestry is locked first, top down (NY40), then the Workflow is
      # reloaded as with_lock would.
      Workflow.transaction do
        Lineage.lock!(workflow)
        workflow.reload(lock: true)
        if workflow.may_cancel? || workflow.may_dismiss?
          workflow.artifacts = workflow.artifacts.to_h.merge(staged_changes).merge(artifacts.to_h.deep_stringify_keys)
          # Root-cause event is recorded before cancel! kicks off terminal cleanup.
          Workflows::CancellationAttribution.record!(workflow, reason: reason, cause: cause)
          workflow.finished_at = Time.current
          workflow.may_cancel? ? workflow.cancel! : workflow.dismiss!
          workflow.work_unit&.preempt!(reason: reason, by_work_unit: by_work_unit)
        end
      end

      workflow
    end

    private

    attr_reader :workflow, :reason, :artifacts, :by_work_unit, :cause
  end
end
