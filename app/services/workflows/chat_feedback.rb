module Workflows
  # Operator-submitted feedback from Syrus Chat. Same execution shape as
  # PR feedback, but the prompt source is the chat_feedback artifact instead
  # of GitHub comments.
  class ChatFeedback < Base
    steps :prepare,
          Workflows::RetryUntil.new(repair: [ :respond ], check: [ :grader_fanout, :grader_collect ]),
          :summarize_amend,
          :push

    def self.trigger_kind = "chat_feedback"

    def self.steps_for(_job)
      [
        "prepare",
        Workflows::RetryUntil.new(
          max_iterations: AppSetting.grade_max_iterations,
          repair: [ :respond ],
          check: [ :grader_fanout, :grader_collect ]
        ),
        "summarize_amend",
        "push"
      ]
    end
  end
end
