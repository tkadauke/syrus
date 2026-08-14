module Workflows
  # Operator-submitted feedback from Syrus Chat. Same execution shape as
  # PR feedback, but the prompt source is the chat_feedback artifact instead
  # of GitHub comments.
  class ChatFeedback < Base
    extend Workflows::FeedbackHandling

    def self.trigger_kind = "chat_feedback"

    def self.steps_for(job)
      prepare_then(
        job,
        adversarial_review_loop(job, agent_step: :respond),
        visual_review_loop(job, agent_step: :respond),
        grader_retry_loop(:respond),
        feedback_finish_steps
      )
    end

    def self.after_success(workflow)
      mark_source_comments_handled(workflow)
    end

    def self.after_fail(workflow)
      mark_source_comments_failed(workflow)
    end

    def self.after_cancel(workflow)
      mark_source_comments_failed(workflow)
    end
  end
end
