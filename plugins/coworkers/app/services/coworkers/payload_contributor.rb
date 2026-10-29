module Coworkers
  class PayloadContributor
    include Syrus::Plugin::ChatPayloadContributor

    def self.chat_payload(chat_session:, context:)
      link = Coworkers::Chat.includes(coworker: { avatar_attachment: :blob }).find_by(chat_session_id: chat_session.id)
      return {} unless link

      coworker = link.coworker
      { agent_appearance: {
        name: coworker.name, accent_hex: coworker.accent_hex, avatar_key: coworker.avatar_key,
        avatar_url: coworker.avatar_url
      } }
    end
  end
end
