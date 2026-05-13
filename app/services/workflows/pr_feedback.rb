module Workflows
  # Reviewer left a comment on the PR. Address it on the existing
  # branch, push.
  #
  #   prepare → loop(respond, grade) → summarize_amend → push
  #
  # respond runs the agent with the comment text + diff context —
  # *fresh* claude session (no --resume from the prior workflow's
  # implement; cross-workflow resume gets unwieldy and the prompt
  # already carries the context the agent needs). summarize_amend
  # --resumes respond and produces the *commit message for the
  # amendment* (not a fresh PR title). push is non-agentic.
  class PrFeedback < Base
    steps :prepare, Workflows::Loop.new(steps: [ :respond, :grade ]), :summarize_amend, :push

    def self.trigger_kind = "pr_comment"

    def self.steps_for(_job)
      [
        "prepare",
        Workflows::Loop.new(max_iterations: AppSetting.grade_max_iterations, steps: [ :respond, :grade ]),
        "summarize_amend",
        "push"
      ]
    end
  end
end
