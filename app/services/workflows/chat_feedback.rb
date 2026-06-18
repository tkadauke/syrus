module Workflows
  # Operator feedback from Syrus Chat. Address it on the existing
  # branch, push.
  #
  #   prepare → retry_until(respond, grade) → summarize_amend → push
  #
  # respond reads the markdown feedback from artifacts["chat_feedback"].
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
