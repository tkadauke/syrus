module Coworkers
  class PayloadContributor
    include Syrus::Host::ChatPayloadContributor

    def self.chat_payload(chat_session:, context:)
      link = Coworkers::Chat.includes(coworker: { avatar_attachment: :blob }).find_by(chat_session_id: chat_session.id)
      payload = { agent_roster: roster_json(chat_session) }
      return payload unless link

      coworker = link.coworker
      payload.merge(chat_capabilities: { mode_selection: false }, agent_appearance: {
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
          removable: chat_session.user_id == Syrus::Host::Current.user&.id, after_reply: entry.after_reply
        }
      end
    end

    def self.message_presentations(messages:)
      metadata = messages.map { |message| coworker_message_metadata(message) }
      ids = metadata.compact.flat_map { |entry| [ entry["sender_id"], entry["receiver_id"] ] }.compact.map(&:to_i).uniq
      owner_ids = messages.map(&:chat_session).map(&:user_id).uniq
      coworkers = Coworkers::Coworker.where(id: ids, owner_user_id: owner_ids)
        .includes(avatar_attachment: :blob)
        .index_by { |coworker| [ coworker.owner_user_id, coworker.id ] }
      bridge_chat_ids = messages.filter_map do |message|
        content = message.content
        next unless content.is_a?(Hash)

        content["origin_chat_session_id"] if content["requested_by"] == "cross_chat" || content["source"] == "coworker_message"
      end.uniq
      bridge_coworkers = Coworkers::Chat.where(chat_session_id: bridge_chat_ids)
        .includes(coworker: { avatar_attachment: :blob }, chat_session: :user)
        .index_by { |link| [ link.chat_session.user_id, link.chat_session_id ] }

      messages.zip(metadata).to_h do |message, entry|
        decorated = {}
        owner_id = message.chat_session.user_id
        content = message.content.is_a?(Hash) ? message.content : {}
        bridge_chat_id = content["origin_chat_session_id"] if content["requested_by"] == "cross_chat" || content["source"] == "coworker_message"
        bridge_link = bridge_coworkers[[ owner_id, bridge_chat_id ]]
        if bridge_link
          decorated[:plugin_message] = message_presentation(appearance: appearance_json(bridge_link.coworker), direction: "incoming", handle: bridge_link.coworker.handle, working_chat_id: bridge_chat_id)
        elsif entry&.fetch("direction", nil) == "incoming" && (coworker = coworkers[[ owner_id, entry["sender_id"].to_i ]])
          decorated[:plugin_message] = message_presentation(appearance: appearance_json(coworker), direction: "incoming", handle: entry["sender_handle"])
        elsif entry&.fetch("direction", nil) == "outgoing" && (coworker = coworkers[[ owner_id, entry["receiver_id"].to_i ]])
          decorated[:plugin_message] = message_presentation(appearance: appearance_json(coworker), direction: "outgoing", handle: entry["receiver_handle"])
        elsif entry
          decorated[:plugin_message] = message_presentation(appearance: nil, direction: entry["direction"], handle: entry["sender_handle"] || entry["receiver_handle"])
        end
        decorated[:author] = decorated.dig(:plugin_message, :data, :appearance)&.slice(:id, :name, :handle, :accent_hex, :avatar_key, :avatar_url)
        [ message.id, decorated ]
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

    def self.message_presentation(appearance:, direction:, handle:, working_chat_id: nil)
      data = { appearance: appearance, direction: direction, handle: handle }
      data[:working_chat_id] = working_chat_id if working_chat_id
      { component: "coworkers/CoworkerMessage", data: data }
    end
  end
end
