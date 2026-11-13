module PersonalDocuments
  class Origin
    CHAT_UPLOAD_PATTERN = %r{\Achat-message-image://(?<chat_id>\d+)/}.freeze
    CHAT_CAPTURE_PATTERN = %r{\Achat-captured-image://(?<chat_id>\d+)/}.freeze

    def self.for(document, chats_by_id:)
      source_url = document.source_url.to_s
      match = CHAT_UPLOAD_PATTERN.match(source_url)
      return ChatUpload.new(match[:chat_id], chats_by_id:) if match

      match = CHAT_CAPTURE_PATTERN.match(source_url)
      return ChatCapture.new(match[:chat_id], chats_by_id:) if match

      Manual.new
    end

    class Manual
      def as_json
        { kind: "personal", chat: nil }
      end
    end

    class ChatOrigin
      def initialize(chat_id, chats_by_id:)
        @chat_id = chat_id.to_i
        @chat = chats_by_id[@chat_id]
      end

      def as_json
        { kind:, chat: chat_json }
      end

      private

      def chat_json
        return nil unless @chat

        { id: @chat.id, label: "CHAT-#{@chat.id}", path: "/chats/#{@chat.id}" }
      end
    end

    class ChatUpload < ChatOrigin
      private

      def kind = "chat_upload"
    end

    class ChatCapture < ChatOrigin
      private

      def kind = "chat_capture"
    end
  end
end
