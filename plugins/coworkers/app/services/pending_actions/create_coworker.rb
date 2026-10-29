module PendingActions
  class CreateCoworker < Base
    action_key "create_coworker"
    requires_chat_session!

    def execute
      progress!("Creating coworker...")
      Coworkers::Create.call(owner: user, **payload.symbolize_keys)
    end

    def validate_payload(errors)
      %w[name handle workspace_repo].each do |field|
        errors.add(:payload, "#{field} is required") if payload[field].blank?
      end
    end

    def presentation_label = "Create coworker @#{payload['handle']}"
    def presentation_detail = [ payload["name"], payload["workspace_repo"] ].compact.join(" · ")

    def tool_card_outcome
      return unless action.result_type == "Coworkers::Coworker" && action.result_id.present?

      chat_id = Coworkers::Chat.find_by(coworker_id: action.result_id, role: "main")&.chat_session_id
      { coworker_id: action.result_id, chat_id: chat_id }.compact
    end
  end
end
