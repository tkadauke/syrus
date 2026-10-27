module RetryJobs
  module Modes
    class Implementation < Mode
      IMPLEMENTATION_FAILURE_STEP_KINDS = %w[
        prepare
        implement
        grader_fanout
        grader
        grader_collect
      ].freeze
      GIT_STATE_CORRUPT_PROBLEM_CODE = "git_state_corrupt".freeze
      FRESH_IMPLEMENTATION_ESCAPE_TRIGGER_KINDS = %w[base_refresh_retry rebase stack_rebase].freeze

      def initialize(job:, agent_provider: nil, retry_context: nil, **)
        super(job: job)
        @agent_provider = agent_provider.to_s.presence
        @retry_context = retry_context.to_s.strip.presence
      end

      def preflight
        return failure("No changes were needed, so there is no implementation to retry.") if job.no_change_needed?
        return failure("Infrastructure workflows cannot be retried as implementation work.") if latest_workflow&.infrastructure_workflow?

        common = retry_preflight
        return common unless common.eligible?
        unless job.failed? || latest_workflow&.failed? || latest_workflow&.cancelled?
          return failure("The latest workflow did not fail or get cancelled.")
        end
        return failure("Landing workflows must be retried with their landing action.") if latest_workflow&.landing_workflow?

        step = failed_step unless fresh_implementation_escape?
        if step.present? &&
            !IMPLEMENTATION_FAILURE_STEP_KINDS.include?(step.kind) &&
            !failed_step_workspace_git_state_corrupt?(step)
          return failure("The failed #{Step::Kind.label_for(step.kind)} step should be retried from that step.")
        end

        success("base_ref" => job.effective_base_branch)
      end

      def execute
        RetryWorkflowEnqueuer.call(job: job, agent_provider: @agent_provider,
          provider_validation: :retry_alternate, resume_checkpoint: false, retry_kind: "retry",
          artifacts: {
            RebaseTarget::BASE_BRANCH_ARTIFACT => job.effective_base_branch,
            "skip_existing_branch_checkout" => true,
            "implementation_retry" => true,
            "replay_context" => @retry_context
          }.compact)
      end

      private

      def latest_workflow
        @latest_workflow ||= job.latest_workflow
      end

      def failed_step
        @failed_step ||= RetryFailedStepEnqueuer.failed_step_for(latest_workflow) if latest_workflow&.failed?
      end

      def fresh_implementation_escape?
        FRESH_IMPLEMENTATION_ESCAPE_TRIGGER_KINDS.include?(latest_workflow&.trigger_kind)
      end

      def failed_step_workspace_git_state_corrupt?(step)
        classification = step.latest_run&.run_failure_classification&.classification
        return false if classification.blank?

        Problem::Kind.resolve(classification)&.code == GIT_STATE_CORRUPT_PROBLEM_CODE
      end
    end
  end
end
