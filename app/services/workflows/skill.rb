module Workflows
  # A freeform agent execution driven by a named Skills:: instruction set
  # (EPIC-233) rather than an issue body. Launched from a `direct` Job
  # carrying `skill_name` + `skill_args` (see Job#skill_launch?).
  #
  #   prepare → run_skill → retry_until(run_skill → graders) → summarize → pr_open
  #
  # The "pr_open if diff present, else no_changes" conditional isn't a
  # distinct control node: run_skill raises Steps::Base::NoChangesProduced
  # when the agent commits nothing (same as implement), which fails the
  # step before the grader retry loop (or summarize/pr_open) ever runs.
  # Workflow#propagate_fail_to_job! then closes the Job with
  # closure_reason=no_changes — the same happy path cron Jobs already use
  # for a no-op survey.
  #
  # Grading is intentionally scoped to the same retry_until(agent_step →
  # graders) mechanism `initial`/`retry` use — not the adversarial_review or
  # visual_review loops those chains also run. This closes the "PR opened
  # with zero automated verification" gap without expanding skill runs to
  # match `initial`'s full review bar.
  class Skill < Base
    def self.trigger_kind = "skill"

    def self.steps_for(job)
      prepare_then(job, grader_retry_loop(:run_skill), "summarize", "pr_open")
    end
  end
end
