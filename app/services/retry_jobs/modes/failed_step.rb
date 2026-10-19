module RetryJobs
  module Modes
    class FailedStep < Mode
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
        RetryFailedStepEnqueuer.call(workflow: source_workflow)
      end
    end
  end
end
