module Workflows
  # Operator clicked "Retry" on a Job — start over on the same
  # branch as if it were Initial. Same shape as Initial; the
  # difference is per-step behavior: implement on a retry reuses
  # the existing branch instead of branching from default; pr_open
  # short-circuits if the Job already has a PR number.
  class Retry < Base
    def self.trigger_kind = "retry"

    def self.steps_for(job)
      syrus_yml = resolve_default_branch_syrus_yml(job)
      prepare_then(
        job,
        adversarial_review_loop(job, agent_step: :implement, syrus_yml: syrus_yml),
        visual_review_loop(job, agent_step: :implement, syrus_yml: syrus_yml),
        grader_retry_loop(job, :implement, autofix: true, syrus_yml: syrus_yml),
        "coverage_analyze",
        "dependency_audit",
        initial_pr_finish_steps(job, syrus_yml: syrus_yml)
      )
    end
  end
end
