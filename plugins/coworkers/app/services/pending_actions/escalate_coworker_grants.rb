module PendingActions
  class EscalateCoworkerGrants < Base
    action_key "escalate_coworker_grants"
    requires_chat_session!

    def execute
      progress!("Granting coworker capabilities...")
      Coworkers::GrantEscalation.call(
        owner: user, coworker_id: payload.fetch("coworker_id"), grants: payload.fetch("grants")
      )
    end

    def validate_payload(errors)
      errors.add(:payload, "coworker_id is required") if payload["coworker_id"].blank?
      errors.add(:payload, "grants are required") if Array(payload["grants"]).empty?
    end

    def presentation_label = "Grant capabilities to @#{payload['handle']}"
    def presentation_detail = Array(payload["grants"]).join(", ")
  end
end
