module PendingActions
  class AdminUnpauseUserScheduling < Base
    action_key "admin_unpause_user_scheduling"

    def execute
      Admin::Users::Payload.new(params: {}, actor: user).unpause_scheduling(payload.fetch("user_id"))
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "user_id is required") unless payload["user_id"].present?
    end

    def action_detail
      "user_id: #{payload["user_id"]}"
    end
  end
end
