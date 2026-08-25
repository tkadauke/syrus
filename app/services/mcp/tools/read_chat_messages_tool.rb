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

        payload = {
          messages: messages.map { |message| message_payload(message) },
          page: page,
          has_more: has_more,
          next_page: (page + 1 if has_more),
          chat_title: chat_session.title.presence || ChatSession.fallback_title_for(chat_session.repository)
        }
        payload.merge!(chat_session_deletion_payload(chat_session)) if admin?

        Mcp::Tools.success(payload)
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
        base = ChatMessage.where(chat_session_id: chat_session.id)
        scope = admin? ? base : base.active
        return scope unless mysql_adapter?

        scope.from(Arel.sql("#{ChatMessage.quoted_table_name} FORCE INDEX (idx_chat_messages_session_created_id)"))
      end

      def mysql_adapter?
        ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")
      end

      def message_payload(message)
        payload = {
          id: message.id,
          role: message.role,
          content: message.content,
          created_at: message.created_at&.iso8601
        }
        payload.merge!(deletion_payload(message.deleted_at, message.deleted_by_user)) if admin? && message.deleted?
        payload
      end

      def chat_session_deletion_payload(chat_session)
        return {} unless chat_session.deleted?

        {
          chat_session_deleted_at: chat_session.deleted_at&.iso8601,
          chat_session_deleted_by: user_summary(chat_session.deleted_by_user)
        }
      end

      def deletion_payload(deleted_at, deleted_by_user)
        {
          deleted_at: deleted_at&.iso8601,
          deleted_by: user_summary(deleted_by_user)
        }
      end

      def user_summary(user)
        return nil unless user

        { id: user.id, name: user.display_name, email: user.email_address }
      end
    end
  end
end
