module RetryJobs
  module Modes
    class RefreshBase < Mode
      def preflight
        return failure("A reason is required for a base refresh retry.") if reason.blank?
        return failure("Active mutation work must finish before retrying this Job.") if WorkUnits::Ownership.active_for_job?(job)

        eligibility = BaseRefreshRetryEligibility.call(job: job, source_workflow_id: source_workflow_id)
        return failure(eligibility.message) unless eligibility.eligible?

        success("source_workflow_id" => eligibility.workflow.id,
          "checkpoint_id" => eligibility.checkpoint.id,
          "checkpoint_sha" => eligibility.checkpoint.commit_sha,
          "base_ref" => job.effective_base_branch)
      end

      def execute
        BaseRefreshRetryEnqueuer.call(job: job, source_workflow: source_workflow, reason: reason)
      end
    end
  end
end
