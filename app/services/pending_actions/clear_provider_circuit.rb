module PendingActions
  class ClearProviderCircuit < Base
    action_key "clear_provider_circuit"

    def execute
      ProviderCircuitClearance.call(
        provider: payload.fetch("provider"),
        target_user: User.find(payload.fetch("user_id")),
        mode: payload.fetch("mode", "clear"),
        retry_after: payload["retry_after"],
        positive_evidence: payload.fetch("positive_evidence"),
        reason: reason,
        user: user
      )
    end

    def validate_payload(errors)
      errors.add(:payload, "provider is required") if payload["provider"].blank?
      errors.add(:payload, "user_id is required") if payload["user_id"].blank?
      errors.add(:payload, "positive_evidence is required") if payload["positive_evidence"].blank?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "provider: #{payload["provider"]}, user_id: #{payload["user_id"]}, mode: #{payload.fetch("mode", "clear")}"
    end

    def repair_action? = true
  end
end
