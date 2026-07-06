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
      return unless latest_workflow&.retry_available?
      return unless failed_step

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
      eligibility = RetryWorkflowEligibility.call(job: job)
      return false unless eligibility.eligible?
      return false if job.landing_failure_reason.present?
      return false unless job.failed? || latest_workflow&.failed?
      return false if latest_workflow&.landing_workflow?
      return false unless IMPLEMENTATION_TRIGGER_KINDS.include?(latest_workflow&.trigger_kind)

      failed_step.blank? || IMPLEMENTATION_FAILURE_STEP_KINDS.include?(failed_step.kind)
    end

    def failed_step_label
      Workflow::TriggerKind.retry_label_for(latest_workflow.trigger_kind, step_kind: failed_step&.kind)
    end
  end
end
