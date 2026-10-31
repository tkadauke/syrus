module Coworkers
  class PayloadContributor
    include Syrus::Plugin::ChatPayloadContributor

    def self.chat_payload(chat_session:, context:)
      link = Coworkers::Chat.includes(coworker: { avatar_attachment: :blob }).find_by(chat_session_id: chat_session.id)
      payload = { agent_roster: roster_json(chat_session) }
      return payload unless link

      coworker = link.coworker
      payload.merge(coworker_chat: true, agent_appearance: {
        name: coworker.name, accent_hex: coworker.accent_hex, avatar_key: coworker.avatar_key,
        avatar_url: coworker.avatar_url
      })
    end

    def self.roster_json(chat_session)
      Coworkers::ChatAgent.where(chat_session: chat_session).includes(coworker: { avatar_attachment: :blob }).order(:id).map do |entry|
        coworker = entry.coworker
        {
          id: coworker.id, name: coworker.name, handle: coworker.handle,
          accent_hex: coworker.accent_hex, avatar_key: coworker.avatar_key, avatar_url: coworker.avatar_url,
          removable: chat_session.user_id == Current.user&.id
        }
      end
    end

    def self.chat_message_payload(messages:, payloads:)
      metadata = messages.map { |message| coworker_message_metadata(message) }
      ids = metadata.compact.flat_map { |entry| [ entry["sender_id"], entry["receiver_id"] ] }.compact.map(&:to_i).uniq
      owner_ids = messages.map(&:chat_session).map(&:user_id).uniq
      coworkers = Coworkers::Coworker.where(id: ids, owner_user_id: owner_ids)
        .includes(avatar_attachment: :blob)
        .index_by { |coworker| [ coworker.owner_user_id, coworker.id ] }

      payloads.zip(messages, metadata).map do |payload, message, entry|
        next payload unless entry

        decorated = payload.dup
        owner_id = message.chat_session.user_id
        if entry["direction"] == "incoming" && (coworker = coworkers[[ owner_id, entry["sender_id"].to_i ]])
          decorated[:coworker_sender] = appearance_json(coworker)
        elsif entry["direction"] == "outgoing" && (coworker = coworkers[[ owner_id, entry["receiver_id"].to_i ]])
          decorated[:coworker_receiver] = appearance_json(coworker)
        end
        decorated
      end
    end

    def self.coworker_message_metadata(message)
      content = message.content
      return unless content.is_a?(Hash) && content["source"] == "coworker_message"

      content["coworker_message"] if content["coworker_message"].is_a?(Hash)
    end

    def self.appearance_json(coworker)
      {
        id: coworker.id, name: coworker.name, handle: coworker.handle,
        accent_hex: coworker.accent_hex, avatar_key: coworker.avatar_key, avatar_url: coworker.avatar_url
      }
    end
  end
end
