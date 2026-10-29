module Coworkers
  class PayloadContributor
    include Syrus::Plugin::ChatPayloadContributor

    def self.chat_payload(chat_session:, context:)
      link = Coworkers::Chat.includes(coworker: { avatar_attachment: :blob }).find_by(chat_session_id: chat_session.id)
      payload = { agent_roster: roster_json(chat_session) }
      return payload unless link

      coworker = link.coworker
      payload.merge(agent_appearance: {
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
  end
end
