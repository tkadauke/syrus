module Workflows
  # Operator-submitted feedback from Syrus Chat. Same execution shape as
  # PR feedback, but the prompt source is the chat_feedback artifact instead
  # of GitHub comments.
  class ChatFeedback < Base
    steps :prepare,
          Workflows::RetryUntil.new(repair: [ :respond ], check: [ :grader_fanout, :grader_collect ]),
          :coverage_analyze,
          :coverage_pr_comment,
          :summarize_amend,
          follow_up_push

    def self.trigger_kind = "chat_feedback"

    def self.steps_for(job)
      [
        "prepare",
        adversarial_review_loop(job),
        Workflows::RetryUntil.new(
          max_iterations: AppSetting.grade_max_iterations,
          repair: [ :respond ],
          check: [ :grader_fanout, :grader_collect ]
        ),
        "coverage_analyze",
        "coverage_pr_comment",
        "summarize_amend",
        follow_up_push(max_iterations: AppSetting.grade_max_iterations)
      ].compact
    end

    def self.adversarial_review_loop(job)
      rounds = adversarial_review_rounds(job)
      return nil unless rounds.positive?

      Workflows::Loop.new(max_iterations: rounds, steps: [ :respond, :adversarial_review ])
    end
  end
end
