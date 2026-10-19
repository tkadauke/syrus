module RetryJobs
  module Modes
    class Implementation < Mode
      def preflight
        retry_preflight("base_ref" => job.effective_base_branch)
      end

      def execute
        RetryWorkflowEnqueuer.call(job: job, resume_checkpoint: false,
          artifacts: {
            RebaseTarget::BASE_BRANCH_ARTIFACT => job.effective_base_branch,
            "skip_existing_branch_checkout" => true,
            "implementation_retry" => true
          })
      end
    end
  end
end
