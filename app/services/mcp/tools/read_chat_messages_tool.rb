require "mcp"

module Mcp::Tools
  class ReadChatMessagesTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

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
        chat_session = find_chat_session!(chat_session_id)

        page = normalize_page(page)
        messages, has_more = page_messages(chat_session, page)

        Mcp::Tools.success(
          messages: messages.map { |message| message_payload(message) },
          page: page,
          has_more: has_more,
          next_page: (page + 1 if has_more),
          chat_title: chat_session.title.presence || ChatSession.fallback_title_for(chat_session.repository)
        )
      end

      private

      def normalize_page(value)
        [ value.to_i, 1 ].max
      end

      def page_messages(chat_session, page)
        ids = message_id_scope(chat_session)
          .order(:created_at, :id)
          .offset((page - 1) * ChatSession::MESSAGE_PAGE_SIZE)
          .limit(ChatSession::MESSAGE_PAGE_SIZE + 1)
          .pluck(:id)
        has_more = ids.size > ChatSession::MESSAGE_PAGE_SIZE
        ids = ids.first(ChatSession::MESSAGE_PAGE_SIZE)
        messages_by_id = ChatMessage.where(id: ids).index_by(&:id)

        [ ids.filter_map { |id| messages_by_id[id] }, has_more ]
      end

      def message_id_scope(chat_session)
        scope = ChatMessage.active.where(chat_session_id: chat_session.id)
        return scope unless mysql_adapter?

        scope.from(Arel.sql("#{ChatMessage.quoted_table_name} FORCE INDEX (idx_chat_messages_session_created_id)"))
      end

      def mysql_adapter?
        ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")
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
