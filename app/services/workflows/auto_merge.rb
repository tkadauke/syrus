module Workflows
  # Approved PR is ready to land.
  #
  #   mergeability_preflight → prepare → retry_until(grader_fanout → grader_collect, repair: landing_fix) → push → auto_merge
  #
  # The final gate starts with graders on the exact PR branch Syrus
  # is about to merge, after any final rebase. landing_fix only runs
  # after a failed grade. push publishes fixes from any repair
  # iteration, and auto_merge re-fetches PR state immediately before
  # calling GitHub's merge API.
  class AutoMerge < Base
    def self.trigger_kind = "auto_merge"

    def self.queue_name = :merges

    def self.steps_for(job)
      chain = [
        "mergeability_preflight",
        "prepare",
        landing_grader_retry_loop,
        "push",
        "auto_merge"
      ]
      without_skipped_prepare(job, chain)
    end

    def self.after_success(_workflow)
      LandingQueueProcessor.try_land!
    end

    def self.after_fail(workflow)
      job = workflow.job
      cleanup_unrepaired_workspace(workflow)
      return unless job&.landing?

      LandingFailureHandler.call(job: job, reason: failure_reason_for(workflow), run: latest_failed_run(workflow))
    end

    def self.cleanup_unrepaired_workspace(workflow)
      return if workflow.steps.where(kind: "landing_fix", state: "succeeded").exists?

      WorkflowWorkspace.cleanup_for(workflow)
    end

    def self.failure_reason_for(workflow)
      explicit_reason = workflow.failure_reason.presence || workflow.artifact("failure_reason").presence
      return explicit_reason if explicit_reason

      run = latest_failed_run(workflow)
      diagnostic = run&.run_diagnostic
      return "#{diagnostic.error_class}: #{diagnostic.error_message}" if diagnostic
      return "agent_outcome=#{run.agent_outcome}" if run&.agent_outcome.present?

      "auto_merge workflow failed"
    end

    def self.latest_failed_run(workflow)
      workflow.runs.where(state: "failed").includes(:run_diagnostic).order(created_at: :desc).first
    end
  end
end
