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

        success("source_workflow_id" => workflow.id, "failed_step_id" => step.id,
          "failed_step_kind" => step.kind, "source_snapshot_id" => WorkflowSourceSnapshots.current_for(workflow)&.id)
      end

      def execute
        workflow = source_workflow
        OperatorRetryContext.with_context(workflow, @retry_context) do
          RetryFailedStepEnqueuer.call(workflow: workflow)
        end
      end
    end
  end
end
