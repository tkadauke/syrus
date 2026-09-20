module App
  class JobRetryActions
    IMPLEMENTATION_TRIGGER_KINDS = %w[initial retry].freeze
    IMPLEMENTATION_FAILURE_STEP_KINDS = %w[
      prepare
      implement
      grader_fanout
      grader
      grader_collect
    ].freeze
    GIT_STATE_CORRUPT_PROBLEM_CODE = "git_state_corrupt".freeze

    def self.for(job)
      new(job).as_json
    end

    def initialize(job)
      @job = job
    end

    def as_json
      {
        failed_step: failed_step_action,
        implementation: implementation_action
      }
    end

    private

    attr_reader :job

    def latest_workflow
      @latest_workflow ||= job.latest_workflow
    end

    def failed_step
      @failed_step ||= RetryFailedStepEnqueuer.failed_step_for(latest_workflow) if latest_workflow&.failed?
    end

    def failed_step_action
      return if job.no_change_needed?
      return if latest_workflow&.infrastructure_workflow?
      return unless latest_workflow&.retry_available?
      return unless failed_step
      return if failed_step_workspace_git_state_corrupt?

      {
        key: "retry_failed_step",
        label: failed_step_label,
        workflow_id: latest_workflow.id,
        step_id: failed_step.id,
        step_kind: failed_step.kind,
        step_label: Step::Kind.label_for(failed_step.kind),
        path: "/api/v1/app/jobs/#{job.id}/workflows/#{latest_workflow.id}/retry_step"
      }
    end

    def implementation_action
      return unless implementation_retry_available?

      {
        key: "retry_implementation",
        label: "Retry implementation",
        path: "/api/v1/app/jobs/#{job.id}/run_again"
      }
    end

    def implementation_retry_available?
      return false if job.no_change_needed?
      return false if latest_workflow&.infrastructure_workflow?
      eligibility = RetryWorkflowEligibility.call(job: job)
      return false unless eligibility.eligible?
      return false if job.landing_failure_reason.present?
      return false unless job.failed? || latest_workflow_retryable_as_implementation?
      return false if latest_workflow&.landing_workflow?
      return false unless IMPLEMENTATION_TRIGGER_KINDS.include?(latest_workflow&.trigger_kind)

      failed_step.blank? ||
        IMPLEMENTATION_FAILURE_STEP_KINDS.include?(failed_step.kind) ||
        failed_step_workspace_git_state_corrupt?
    end

    def latest_workflow_retryable_as_implementation?
      latest_workflow&.failed? || latest_workflow&.cancelled?
    end

    def failed_step_label
      return "Restart grade loop" if failed_step&.kind == "grader_fanout" && failed_step.loop_id.present?

      Workflow::TriggerKind.retry_label_for(latest_workflow.trigger_kind, step_kind: failed_step&.kind)
    end

    # The failed step's own workspace has no valid git HEAD, not the step
    # itself -- so the IMPLEMENTATION_FAILURE_STEP_KINDS allowlist doesn't
    # apply, and resuming the same step in place (retry_failed_step) is
    # guaranteed to hit the same WorkflowWorkspace refusal every time. Only
    # a full restart (a fresh Workflow + fresh workspace) can recover.
    def failed_step_workspace_git_state_corrupt?
      return false unless failed_step

      classification = failed_step.latest_run&.run_failure_classification&.classification
      return false if classification.blank?

      Problem::Kind.resolve(classification)&.code == GIT_STATE_CORRUPT_PROBLEM_CODE
    end
  end
end
