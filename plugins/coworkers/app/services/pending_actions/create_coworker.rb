module PendingActions
  class CreateCoworker < Base
    action_key "create_coworker"
    requires_chat_session!

    def self.preload_tool_card_outcomes(actions)
      coworker_ids = actions.filter_map { |action| action.result_id if action.result_type == "Coworkers::Coworker" }
      return {} if coworker_ids.empty?

      chat_ids = Coworkers::Chat.where(coworker_id: coworker_ids, role: "main").pluck(:coworker_id, :chat_session_id).to_h
      actions.each_with_object({}) do |action, outcomes|
        next unless action.result_type == "Coworkers::Coworker" && action.result_id.present?

        outcomes[action.id] = { coworker_id: action.result_id, chat_id: chat_ids[action.result_id] }.compact
      end
    end

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
    def tool_card_review = { about: payload["about"] }

    def tool_card_outcome
      return unless action.result_type == "Coworkers::Coworker" && action.result_id.present?

      { coworker_id: action.result_id }
    end
  end
end
