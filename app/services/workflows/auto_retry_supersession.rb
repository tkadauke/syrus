module Workflows
  # Whether an auto-retry's source Workflow no longer needs retrying. One rule,
  # used by both AutoRetryJob (before launching the retry) and the reconciler's
  # stale_auto_retry_workflow classifier (after). When the two disagreed, a
  # retry passed the launch check, started, and was cancelled as stale moments
  # later -- leaving a requested WorkIntent the launcher materialized again.
  module AutoRetrySupersession
    module_function

    def superseded?(source)
      return false unless source

      source.succeeded? ||
        Workflows::ValidationSupersession.superseded_by_successful_workflow?(source) ||
        divergence_recovered_by_current_pr_branch?(source)
    end

    def divergence_recovered_by_current_pr_branch?(source)
      recovery = source.artifact("branch_divergence_recovery")
      recovery.is_a?(Hash) && recovery["action"] == "superseded_by_current_pr_branch"
    end
  end
end
