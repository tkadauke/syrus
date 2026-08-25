require "mcp"

module Mcp::Tools
  class SearchChatsTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

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
        return Mcp::Tools.invalid("query is required") if query.blank?

        results = ChatMessageSearchIndex.search(
          query,
          user_id: chat_session.user_id,
          limit: normalize_limit(limit),
          snippet_start: "<b>",
          snippet_end: "</b>",
          snippet_tokens: 50
        )
        results = admin? ? results : reject_deleted(results)

        payload = { results: results.map { |row| result_payload(row) } }
        payload[:message] = "No matching messages found." if payload[:results].empty?

        Mcp::Tools.success(payload)
      end

      private

      # The FTS index lives in a separate `search` database connection, so
      # deletion state can't be joined in SQL; filter out rows whose
      # underlying message has been soft-deleted against the primary DB.
      def reject_deleted_messages(results)
        return results if results.empty?

        active_ids = ChatMessage.active.where(id: results.map { |row| row.fetch(:chat_message_id) }).ids.to_set
        results.select { |row| active_ids.include?(row.fetch(:chat_message_id)) }
      end

      # A soft-deleted ChatSession leaves its messages untouched for audit
      # (see ChatSession#soft_delete_by!), so they would otherwise still
      # surface here. The chat itself must be invisible to the agent, so
      # reject matches whose chat session is gone or soft-deleted.
      def reject_messages_in_deleted_chats(results)
        return results if results.empty?

        active_session_ids = ChatSession.active.where(id: results.map { |row| row.fetch(:chat_session_id) }).ids.to_set
        results.select { |row| active_session_ids.include?(row.fetch(:chat_session_id)) }
      end

      def reject_deleted(results)
        reject_messages_in_deleted_chats(reject_deleted_messages(results))
      end

      def normalize_limit(value)
        value.to_i.clamp(1, 50)
      end

      def result_payload(row)
        chat_session = ChatSession.includes(:attached_repositories).find(row.fetch(:chat_session_id))

        payload = {
          chat_session_id: chat_session.id,
          chat_title: chat_session.title.presence || ChatSession.fallback_title_for(chat_session.repository),
          role: row.fetch(:role),
          snippet: row.fetch(:snippet),
          created_at: row.fetch(:created_at)
        }
        payload.merge!(admin_deletion_payload(row, chat_session)) if admin?
        payload
      end

      # Admin callers additionally see whether the matched message and/or
      # its chat session have been soft-deleted, and by whom.
      def admin_deletion_payload(row, chat_session)
        payload = {}

        if chat_session.deleted?
          payload[:chat_session_deleted_at] = chat_session.deleted_at&.iso8601
          payload[:chat_session_deleted_by] = user_summary(chat_session.deleted_by_user)
        end

        message = ChatMessage.find_by(id: row.fetch(:chat_message_id))
        if message&.deleted?
          payload[:deleted_at] = message.deleted_at&.iso8601
          payload[:deleted_by] = user_summary(message.deleted_by_user)
        end

        payload
      end

      def user_summary(user)
        return nil unless user

        { id: user.id, name: user.display_name, email: user.email_address }
      end
    end
  end
end
