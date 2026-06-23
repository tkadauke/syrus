require "mcp"

module SyrusChatMcp
  class ListChatsTool < MCP::Tool
    tool_name "list_chats"

    description "List the current operator's recent Syrus chat sessions."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        sessions = ChatSession
          .where(user: chat_session.user)
          .includes(:messages, :attached_repositories)
          .order(updated_at: :desc)
          .limit(20)

        SyrusChatMcp.success(chats: sessions.map { |session| payload_for(session) })
      end

      private

      def payload_for(session)
        repository = session.attached_repositories.first

        {
          id: session.id,
          title: session.title.presence || ChatSession.fallback_title_for(repository),
          repository: repository&.slug,
          message_count: session.messages.size,
          updated_at: session.updated_at.iso8601
        }
      end
    end
  end
end
