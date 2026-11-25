module Coworkers::MentionMessageCallback
  extend ActiveSupport::Concern

  private

  def delegate_coworker_mention
    coworker_delivery = role == "assistant" && content.is_a?(Hash) && content["source"] == "coworker_message"
    return unless role == "user" || coworker_delivery
    return unless skip_turn_trigger
    return if content.is_a?(Hash) && content["source"] == "coworker_mention"

    message_mentions = role == "user" ? resolved_mentions : Syrus::Host::MentionablesResolver.resolve(text: extract_text_from_content, chat: chat_session)
    coworker_ids = message_mentions.filter_map { |mention| mention["id"].to_i if mention["kind"] == "coworker" }
    coworker = Coworkers::ChatAgent.where(chat_session_id: chat_session_id, coworker_id: coworker_ids)
      .includes(:coworker).index_by(&:coworker_id).then { |roster| coworker_ids.filter_map { |id| roster[id]&.coworker }.first }
    Coworkers::MentionDeliveryJob.perform_later(id, coworker.id) if coworker
  end
end
