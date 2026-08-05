module PendingActions
  class WakeProviderAdmission < Base
    action_key "wake_provider_admission"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      ProviderAdmissionWakeup.call(
        provider: payload.fetch("provider"),
        user: payload["user_id"].present? ? User.find(payload["user_id"]) : nil
      )
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "provider is required") if payload["provider"].blank?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "provider: #{payload["provider"]}, user_id: #{payload["user_id"] || "all"}"
    end

    def repair_action? = true
  end
end
