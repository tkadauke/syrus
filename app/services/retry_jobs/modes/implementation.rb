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
      FRESH_IMPLEMENTATION_ESCAPE_TRIGGER_KINDS = %w[base_refresh_retry rebase stack_rebase].freeze
      AGENT_BLOCKED_RETIRED_REASON = "retired_for_implementation_retry"

      def initialize(job:, agent_provider: nil, retry_context: nil, explicit_operator_intent: false,
                     source_workflow_id: nil, reason: nil, **)
        super(job: job, source_workflow_id: source_workflow_id, reason: reason)
        @agent_provider = agent_provider.to_s.presence
        @retry_context = retry_context.to_s.strip.presence
        @explicit_operator_intent = explicit_operator_intent
      end

      def preflight
        return failure("No changes were needed, so there is no implementation to retry.") if job.no_change_needed?
        return failure("Infrastructure workflows cannot be retried as implementation work.") if latest_workflow&.infrastructure_workflow?

        common = retry_preflight(retiring_workflow: agent_blocked_workflow)
        return common unless common.eligible?
        unless job.failed? || latest_workflow&.failed? || latest_workflow&.cancelled? || agent_blocked_workflow
          return failure("The latest workflow did not fail or get cancelled.")
        end
        return failure("Landing workflows must be retried with their landing action.") if latest_workflow&.landing_workflow?

        step = failed_step unless fresh_implementation_escape? || explicit_operator_intent?
        if step.present? &&
            !IMPLEMENTATION_FAILURE_STEP_KINDS.include?(step.kind) &&
            !RetryFailedStepEnqueuer.fresh_workflow_required_for?(step)
          return failure("The failed #{Step::Kind.label_for(step.kind)} step should be retried from that step.")
        end

        success(audit_details)
      end

      def execute
        retire_agent_blocked_workflow!
        RetryWorkflowEnqueuer.call(job: job, agent_provider: @agent_provider,
          provider_validation: :retry_alternate, resume_checkpoint: false, retry_kind: "retry",
          artifacts: {
            RebaseTarget::BASE_BRANCH_ARTIFACT => job.effective_base_branch,
            "skip_existing_branch_checkout" => true,
            "implementation_retry" => true,
            "retry_requested_mode" => "implementation",
            "retry_source_workflow_id" => failure_workflow&.id,
            "retry_source_failure" => failure_context,
            "replay_context" => @retry_context
          }.compact)
      end

      private

      def latest_workflow
        @latest_workflow ||= job.latest_workflow
      end

      def failure_workflow
        @failure_workflow ||= source_workflow || (latest_workflow if latest_workflow&.failed?) || agent_blocked_workflow
      end

      # A primary implementation Workflow whose agent reported it cannot
      # proceed. Unlike auxiliary work, it keeps its WorkUnit -- and so the
      # Job lock -- blocked, with its workspace already cleaned up. Nothing
      # else releases it short of cancelling the Job, so retrying
      # implementation is the way out: the retry retires it first.
      def agent_blocked_workflow
        return @agent_blocked_workflow if defined?(@agent_blocked_workflow)

        workflow = latest_workflow
        @agent_blocked_workflow = workflow if workflow&.blocked? &&
          workflow.artifact("cannot_proceed").present? &&
          !workflow.landing_workflow? &&
          !Workflow::TriggerKind.non_approval_blocking?(workflow.trigger_kind)
      end

      def retire_agent_blocked_workflow!
        workflow = agent_blocked_workflow
        return unless workflow

        WorkUnits::WorkflowCancellation.cancel!(
          workflow,
          reason: AGENT_BLOCKED_RETIRED_REASON,
          artifacts: { "cancelled_reason" => AGENT_BLOCKED_RETIRED_REASON }
        )
        job.reload.clear_needs_attention!(reason: "agent_cannot_proceed")
        @latest_workflow = nil
      end

      def failed_step
        @failed_step ||= RetryFailedStepEnqueuer.failed_step_for(latest_workflow) if latest_workflow&.failed?
      end

      def explicit_operator_intent? = @explicit_operator_intent

      def audit_details
        {
          "base_ref" => job.effective_base_branch,
          "requested_mode" => "implementation",
          "source_workflow_id" => failure_workflow&.id,
          "source_failure" => failure_context
        }.compact
      end

      def failure_context
        step = failure_workflow && RetryFailedStepEnqueuer.failed_step_for(failure_workflow)
        return unless step

        run = step.latest_run
        {
          "step_id" => step.id,
          "step_kind" => step.kind,
          "run_id" => run&.id,
          "classification" => run&.run_failure_classification&.classification,
          "run_attempts" => step.runs.count
        }.compact
      end

      def fresh_implementation_escape?
        FRESH_IMPLEMENTATION_ESCAPE_TRIGGER_KINDS.include?(latest_workflow&.trigger_kind)
      end
    end
  end
end
