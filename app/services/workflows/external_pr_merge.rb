module Workflows
  # Approved external PR ready to land.
  #
  #   mergeability_preflight → grader_fanout → grader_collect → external_pr_merge
  #
  # Graders run on the external PR's HEAD to validate before merging.
  # No prepare or push steps — Syrus does not own this branch.
  # Grader failure calls fail_landing! to revert the job to :implemented
  # so the operator can address the issues before re-approving.
  class ExternalPrMerge < Base
    steps :mergeability_preflight,
          :grader_fanout,
          :grader_collect,
          :external_pr_merge

    def self.trigger_kind = "external_pr_merge"

    def self.queue_name = :merges

    def self.after_success(_workflow)
      LandingQueueProcessor.try_land!
    end

    def self.after_fail(workflow)
      job = workflow.job
      return unless job&.landing?

      LandingFailureHandler.call(job: job, reason: failure_reason_for(workflow), run: latest_failed_run(workflow))
    end

    def self.failure_reason_for(workflow)
      explicit_reason = workflow.failure_reason.presence || workflow.artifact("failure_reason").presence
      return explicit_reason if explicit_reason

      run = latest_failed_run(workflow)
      diagnostic = run&.run_diagnostic
      return "#{diagnostic.error_class}: #{diagnostic.error_message}" if diagnostic

      "external_pr_merge workflow failed"
    end

    def self.latest_failed_run(workflow)
      workflow.runs.where(state: "failed").includes(:run_diagnostic).order(created_at: :desc).first
    end
  end
end
