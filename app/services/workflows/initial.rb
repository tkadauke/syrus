module Workflows
  # Issue → PR.
  #
  # `implement` is always a top-level step: implementation happens
  # regardless of whether adversarial review or a grade loop are
  # configured for this repository. The optional loops that follow only
  # decide whether (and how) that work gets revised:
  #
  #   prepare → implement
  #     → [loop(adversarial_review first, then implement ⇄ adversarial_review)]
  #     → [loop(visual_review first, then implement ⇄ visual_review)]
  #     → retry_until(format, generate, graders; repair: implement)
  #     → ...
  #
  # prepare reads `.syrus.yml` (or auto-detects from lockfiles)
  # and runs deterministic setup like `bundle install` so the
  # agent doesn't burn turns watching deps download. implement
  # runs the agent end-to-end (multi-turn) on the prepared
  # workspace, makes commits, but does NOT call submit_summary
  # — that's a separate phase.
  #
  # Every review loop is review-first: iteration 1 reviews the preceding
  # agent step's diff directly (no redundant re-implement first) — for the
  # adversarial review loop, that's the top-level `implement`; for the
  # visual review loop that follows it, that's whatever the adversarial
  # loop last produced (its own top-level `implement`, or its last repair).
  # On a `needs_work` verdict, a repair `implement` is always inserted,
  # unconditionally, regardless of remaining budget; if review budget
  # remains, another review follows it, repeating the same decision. Once
  # the last review round's verdict is `needs_work`, the final repair
  # `implement` runs with no trailing review — there's no budget left to
  # act on further feedback. See Workflows::Loop and
  # StepDispatcher#enqueue_next_loop_iteration!.
  #
  # The grade retry loop is `repair_first: false`: the top-level implement
  # (or the adversarial loop's last repair, if that ran) already produced
  # the work to grade, so iteration 1 runs the non-implement grading
  # pipeline (format/generate/graders) directly against it. `implement`
  # only comes back as a repair step once a grader iteration fails.
  #
  # grader_fanout reads `.syrus.yml` from the workspace and
  # materializes one `grader` Step per configured grader between
  # itself and grader_collect (dynamic chain insertion). Each
  # grader runs unconditionally — no short-circuit between graders
  # — so the agent's next iteration prompt has every failure to
  # work with. grader_collect aggregates: if any required grader
  # Step ended :failed, it fails (triggering the retry_until's next
  # iteration); otherwise it succeeds and the chain advances.
  #
  # summarize is a short claude call that --resumes implement's
  # session and asks the agent to call submit_summary; tokens are
  # essentially free because Anthropic's session reuse caches the
  # conversation server-side. test_plan is another short resumed call
  # that stores reviewer-facing test instructions. pr_open is
  # non-agentic — it reads
  # workflow.artifacts["pr_title"]/["pr_body"] and runs
  # PullRequestOpener.
  class Initial < Base
    def self.trigger_kind = "initial"

    def self.steps_for(job)
      prepare_then(
        job,
        :implement,
        adversarial_review_loop(job, agent_step: :implement),
        visual_review_loop(job, agent_step: :implement),
        grader_retry_loop(job, :implement, autofix: true, repair_first: false),
        "coverage_analyze",
        "dependency_audit",
        initial_pr_finish_steps
      )
    end
  end
end
