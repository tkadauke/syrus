module Workflows
  # Operator clicked "Retry" on a Job — start over on the same
  # branch as if it were Initial. Same shape as Initial; the
  # difference is per-step behavior: implement on a retry reuses
  # the existing branch instead of branching from default; pr_open
  # short-circuits if the Job already has a PR number.
  class Retry < Base
    def self.trigger_kind = "retry"

    def self.steps_for(job)
      prepare_then(
        job,
        visual_review_loop(job, agent_step: :implement),
        grader_retry_loop(:implement),
        "coverage_analyze",
        initial_pr_finish_steps
      )
    end
  end
end
