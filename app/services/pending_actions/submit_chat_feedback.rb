module PendingActions
  class SubmitChatFeedback < Base
    action_key "submit_chat_feedback"

    def execute
      job = action_job
      result = ChatFeedbackSubmission.call(
        job: job,
        feedback: payload.fetch("feedback"),
        allowed_states: %w[implemented approved]
      )
      raise ArgumentError, result.error unless result.success?

      result.workflow
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "feedback is required") if payload["feedback"].to_s.strip.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end
  end
end
