module Workflows
  # CI checks went red on the PR's branch. Diagnose, fix, push.
  #
  #   prepare → retry_until(analyze_and_fix, grader_fanout, grader_collect)
  #     → summarize_amend → try(push)
  #     on remote-branch rebase conflict:
  #       push_agent_rebase → retry_until(grade, repair: landing_fix) → push_after_rebase
  #
  # Same shape as PrFeedback structurally; differs in the prompt
  # (Prompts::CiFailure carries the failing-checks payload). The
  # implement phase here is "look at the failing checks, find the
  # root cause, fix the code or the test".
  class CiFailure < Base
    def self.trigger_kind = "ci_failure"

    def self.steps_for(job)
      prepare_then(
        job,
        grader_retry_loop(:analyze_and_fix),
        "summarize_amend",
        follow_up_push(max_iterations: AppSetting.grade_max_iterations)
      )
    end
  end
end
