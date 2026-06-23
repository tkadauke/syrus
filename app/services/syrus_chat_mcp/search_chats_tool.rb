require "mcp"

module SyrusChatMcp
  class SearchChatsTool < MCP::Tool
    tool_name "search_chats"

    description "Search this user's prior chat messages by full-text content."

    input_schema(
      properties: {
        query: { type: "string", description: "Full-text search query." },
        limit: { type: "integer", description: "Maximum messages to return. Defaults to 10, capped at 50." }
      },
      required: %w[query]
    )

    class << self
      def call(server_context:, query:, limit: 10)
        chat_session = server_context.fetch(:chat_session)
        query = query.to_s.strip
        return SyrusChatMcp.invalid("query is required") if query.blank?

        results = ChatMessageSearchIndex.search(
          query,
          user_id: chat_session.user_id,
          limit: normalize_limit(limit),
          snippet_start: "<b>",
          snippet_end: "</b>",
          snippet_tokens: 50
        )

        payload = { results: results.map { |row| result_payload(row) } }
        payload[:message] = "No matching messages found." if payload[:results].empty?

        SyrusChatMcp.success(payload)
      end

      private

      def normalize_limit(value)
        value.to_i.clamp(1, 50)
      end

      def result_payload(row)
        chat_session = ChatSession.includes(:attached_repositories).find(row.fetch(:chat_session_id))

        {
          chat_session_id: chat_session.id,
          chat_title: chat_session.title.presence || ChatSession.fallback_title_for(chat_session.repository),
          role: row.fetch(:role),
          snippet: row.fetch(:snippet),
          created_at: row.fetch(:created_at)
        }
      end
    end
  end
end
