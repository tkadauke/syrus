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
        Workflows::RetryUntil.new(
          max_iterations: AppSetting.grade_max_iterations,
          repair: [ :respond ],
          check: [ :grader_fanout, :grader_collect ]
        ),
        "coverage_analyze",
        "coverage_pr_comment",
        "summarize_amend",
        follow_up_push(max_iterations: AppSetting.grade_max_iterations)
      ]
    end
  end
end
