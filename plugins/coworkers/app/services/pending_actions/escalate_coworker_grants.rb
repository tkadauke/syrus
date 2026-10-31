module PendingActions
  class EscalateCoworkerGrants < Base
    action_key "escalate_coworker_grants"
    requires_chat_session!

    def execute
      progress!("Updating coworker grants...")
      coworker = Coworkers::OwnerResolver.new(owner: user).find!(id: payload.fetch("coworker_id"))
      Coworkers::Grant.transaction do
        payload.fetch("grants").each do |change|
          scope = change.key?("scope") ? { scope: change["scope"] } : {}
          Coworkers::GrantUpdate.call(owner: user, coworker: coworker, capability: change.fetch("capability"),
            approval_policy: change.fetch("policy"), confirmed: true, **scope)
        end
      end
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "coworker_id is required") if payload["coworker_id"].blank?
      errors.add(:payload, "grants are required") if Array(payload["grants"]).empty?
    end

    def presentation_label = "Change grants for @#{payload['handle']}"
    def presentation_detail = Array(payload["grants"]).map { |grant| "#{grant['capability']}: #{grant['policy']}" }.join(", ")
  end
end
