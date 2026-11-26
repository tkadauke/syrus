module RetryJobs
  module Modes
    class FailedStep < Mode
      def initialize(retry_context: nil, **arguments)
        super(**arguments)
        @retry_context = retry_context.to_s.strip.presence
      end

      def preflight
        workflow = source_workflow
        return failure("No failed workflow is available to retry.") unless workflow
        return failure("Active mutation work must finish before retrying this Job.") if WorkUnits::Ownership.active_for_job?(job)

        eligibility = RetryWorkflowEligibility.call(job: job, workflow: workflow)
        return failure(eligibility.message) unless eligibility.eligible?
        return failure("The failed workflow workspace is no longer available.") unless workflow.retry_available?

        step = RetryFailedStepEnqueuer.failed_step_for(workflow)
        return failure("No failed step or grader loop is available to retry.") unless step

        decision = RecoveryDecision.for(job: job, workflow: workflow)
        if decision.kind == "grader_loop_no_progress" && @retry_context.blank?
          return failure("Guidance is required to repair a grader loop that stopped for no measurable progress.")
        end

        success("source_workflow_id" => workflow.id, "failed_step_id" => step.id,
          "failed_step_kind" => step.kind, "source_snapshot_id" => WorkflowSourceSnapshots.current_for(workflow)&.id,
          "recovery_decision" => decision.as_json)
      end

      def execute
        workflow = source_workflow
        decision = RecoveryDecision.for(job: job, workflow: workflow)
        if decision.kind == "grader_loop_no_progress" && @retry_context.blank?
          return RetryFailedStepEnqueuer::Result.new(
            run: nil, workflow: nil, step: nil,
            error: "Guidance is required to repair a grader loop that stopped for no measurable progress."
          )
        end
        OperatorRetryContext.with_context(workflow, @retry_context) do
          RetryFailedStepEnqueuer.call(workflow: workflow)
        end
      end

      def recovery_action
        step = source_workflow && RetryFailedStepEnqueuer.failed_step_for(source_workflow)
        step&.kind == "grader_fanout" ? "restart_grade_loop" : "repair"
      end
    end
  end
end
