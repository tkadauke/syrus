module Coworkers
  class ChatListGroup
    def self.chat_list_group(user:)
      links = Coworkers::Chat.includes(coworker: { avatar_attachment: :blob }).joins(:coworker).where(coworkers: { owner_user_id: user.id })
      metadata = links.index_with do |link|
        coworker = link.coworker
        { agent_appearance: { name: coworker.name, accent_hex: coworker.accent_hex, avatar_key: coworker.avatar_key, avatar_url: coworker.avatar_url } }
      end.transform_keys(&:chat_session_id)
      { key: "coworkers", label: I18n.t("api.coworkers.chat_group"), chat_session_ids: metadata.keys, metadata_by_chat_session_id: metadata }
    end
  end
end
