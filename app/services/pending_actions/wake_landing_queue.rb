module PendingActions
  class WakeLandingQueue < Base
    action_key "wake_landing_queue"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      LandingQueueProcessorJob.perform_later
      nil
    end

    def validate_payload(errors)
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "reason: #{reason}"
    end
  end
end
