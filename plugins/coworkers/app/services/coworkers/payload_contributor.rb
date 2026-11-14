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
      presentations = message_presentations(messages: messages)
      bridge_chat_ids = payloads.filter_map do |payload|
        bridge = payload[:cross_chat_bridge]
        bridge[:counterpart_chat_session_id] if bridge&.fetch(:direction, nil) == "inbound"
      end.uniq
      bridge_coworkers = Coworkers::Chat.where(chat_session_id: bridge_chat_ids)
        .includes(coworker: { avatar_attachment: :blob }, chat_session: :user)
        .index_by { |link| [ link.chat_session.user_id, link.chat_session_id ] }
      payloads.zip(messages).map do |payload, message|
        decorated = payload.merge(presentations.fetch(message.id, {}))
        bridge = payload[:cross_chat_bridge]
        link = bridge_coworkers[[ message.chat_session.user_id, bridge&.fetch(:counterpart_chat_session_id, nil) ]]
        if bridge&.fetch(:direction, nil) == "inbound" && link
          decorated[:coworker_sender] = appearance_json(link.coworker)
        end
        decorated
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
        content["origin_chat_session_id"] if content.is_a?(Hash) && content["requested_by"] == "cross_chat"
      end.uniq
      bridge_coworkers = Coworkers::Chat.where(chat_session_id: bridge_chat_ids)
        .includes(coworker: { avatar_attachment: :blob }, chat_session: :user)
        .index_by { |link| [ link.chat_session.user_id, link.chat_session_id ] }

      messages.zip(metadata).to_h do |message, entry|
        decorated = {}
        owner_id = message.chat_session.user_id
        content = message.content.is_a?(Hash) ? message.content : {}
        bridge_chat_id = content["origin_chat_session_id"] if content["requested_by"] == "cross_chat"
        bridge_link = bridge_coworkers[[ owner_id, bridge_chat_id ]]
        if bridge_link
          decorated[:coworker_sender] = appearance_json(bridge_link.coworker)
        elsif entry&.fetch("direction", nil) == "incoming" && (coworker = coworkers[[ owner_id, entry["sender_id"].to_i ]])
          decorated[:coworker_sender] = appearance_json(coworker)
        elsif entry&.fetch("direction", nil) == "outgoing" && (coworker = coworkers[[ owner_id, entry["receiver_id"].to_i ]])
          decorated[:coworker_receiver] = appearance_json(coworker)
        end
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
  end
end
