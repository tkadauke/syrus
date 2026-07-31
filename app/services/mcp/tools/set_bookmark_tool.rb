require "mcp"

module Mcp::Tools
  class SetBookmarkTool < MCP::Tool
    tool_name "set_bookmark"

    description <<~DESC
      Add a table-of-contents bookmark to the current chat. The bookmark
      anchors to the latest message currently persisted in the chat.
    DESC

    input_schema(
      properties: {
        label: { type: "string", description: "Short noun-phrase label shown in the chat sidebar." },
        kind: { type: "string", enum: %w[topic epic_origin], description: "Bookmark kind. Use topic for topic shifts and epic_origin immediately before proposing an epic." }
      },
      required: %w[label kind]
    )

    class << self
      def call(label:, kind:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        label = label.to_s.strip
        kind = kind.to_s.strip

        return Mcp::Tools.invalid("label is required") if label.empty?
        return Mcp::Tools.invalid("kind must be topic or epic_origin") unless %w[topic epic_origin].include?(kind)

        message = chat_session.messages.order(:created_at, :id).last
        return Mcp::Tools.invalid("cannot bookmark an empty chat") unless message

        bookmark = message.bookmarks.create!(label: label, kind: kind)

        Mcp::Tools.success(
          id: bookmark.id,
          label: bookmark.label,
          kind: bookmark.kind,
          message_id: message.id,
          anchor: "message-#{message.id}"
        )
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
