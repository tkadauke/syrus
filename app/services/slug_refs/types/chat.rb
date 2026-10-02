module SlugRefs
  module Types
    class Chat
      include Syrus::Plugin::SlugType

      def self.prefix = "CHAT"
      def self.display_label = "Chat"
      def self.preview_available? = true

      def self.record_for(id, user:)
        return nil unless user

        user.accessible_chat_sessions.visible.active.find_by(id: id)
      end

      def self.web_path(record)
        "/chats/#{record.id}"
      end

      def self.api_preview_path(record)
        "/api/v1/app/chats/#{record.id}/preview"
      end
    end
  end
end
