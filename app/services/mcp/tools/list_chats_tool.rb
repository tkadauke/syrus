require "mcp"

module Mcp::Tools
  class ListChatsTool < MCP::Tool
    tool_name "list_chats"

    description "List the current operator's recent Syrus chat sessions."

    input_schema(
      properties: {
        page: { type: "integer", description: "1-based page number. Defaults to 1." },
        per_page: { type: "integer", description: "Sessions per page. Defaults to 20, capped at 100." }
      }
    )

    class << self
      def call(server_context:, page: 1, per_page: 20)
        chat_session = server_context.fetch(:chat_session)
        page = normalize_page(page)
        per_page = normalize_per_page(per_page)
        scope = ChatSession
          .where(user: chat_session.user)
          .visible
          .active
          .order(updated_at: :desc)
        total_count = scope.count
        sessions = scope
          .preload(:attached_repositories)
          .offset((page - 1) * per_page)
          .limit(per_page)
          .to_a
        message_counts = message_counts_for(sessions)

        Mcp::Tools.success(
          chats: sessions.map { |session| payload_for(session, message_count: message_counts.fetch(session.id, 0)) },
          pagination: {
            page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: (total_count.to_f / per_page).ceil,
            has_next_page: page * per_page < total_count
          }
        )
      end

      private

      def normalize_page(value)
        [ value.to_i, 1 ].max
      end

      def normalize_per_page(value)
        value.to_i.clamp(1, 100)
      end

      def message_counts_for(sessions)
        ids = sessions.map(&:id)
        return {} if ids.empty?

        ChatMessage.where(chat_session_id: ids).group(:chat_session_id).count
      end

      def payload_for(session, message_count:)
        repository = session.attached_repositories.first

        {
          id: session.id,
          title: session.title.presence || ChatSession.fallback_title_for(repository),
          repository: repository&.slug,
          message_count: message_count,
          updated_at: session.updated_at.iso8601
        }
      end
    end
  end
end
