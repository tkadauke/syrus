require "mcp"

module SyrusChatMcp
  class ReadChatMessagesTool < MCP::Tool
    tool_name "read_chat_messages"

    description "Read a page of messages from one of this user's chat sessions."

    input_schema(
      properties: {
        chat_session_id: { type: "integer", description: "Chat session id to read." },
        page: { type: "integer", description: "One-based page number. Defaults to 1." }
      },
      required: %w[chat_session_id]
    )

    class << self
      def call(server_context:, chat_session_id:, page: 1)
        current_chat = server_context.fetch(:chat_session)
        chat_session = ChatSession.find_by(id: chat_session_id, user_id: current_chat.user_id)
        return SyrusChatMcp.invalid("chat session not found") unless chat_session

        page = normalize_page(page)
        total_messages = chat_session.messages.count
        total_pages = [ (total_messages.to_f / ChatSession::MESSAGE_PAGE_SIZE).ceil, 1 ].max
        messages = chat_session.messages
                               .order(:created_at, :id)
                               .offset((page - 1) * ChatSession::MESSAGE_PAGE_SIZE)
                               .limit(ChatSession::MESSAGE_PAGE_SIZE)

        SyrusChatMcp.success(
          messages: messages.map { |message| message_payload(message) },
          page: page,
          total_pages: total_pages,
          chat_title: chat_session.title.presence || ChatSession.fallback_title_for(chat_session.repository)
        )
      end

      private

      def normalize_page(value)
        [ value.to_i, 1 ].max
      end

      def message_payload(message)
        {
          id: message.id,
          role: message.role,
          content: message.content,
          created_at: message.created_at&.iso8601
        }
      end
    end
  end
end
