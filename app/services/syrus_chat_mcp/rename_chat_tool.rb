require "mcp"

module SyrusChatMcp
  class RenameChatTool < MCP::Tool
    tool_name "rename_chat"

    description <<~DESC
      Rename the current chat session.
    DESC

    input_schema(
      properties: {
        name: {
          type: "string",
          description: "New chat title, up to #{ChatSession::TITLE_MAX_LENGTH} characters."
        }
      },
      required: %w[name]
    )

    class << self
      def call(name:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        name = name.to_s.strip

        return SyrusChatMcp.invalid("name is required") if name.blank?
        if name.length > ChatSession::TITLE_MAX_LENGTH
          return SyrusChatMcp.invalid("name must be #{ChatSession::TITLE_MAX_LENGTH} characters or fewer")
        end

        chat_session.update!(title: name)

        SyrusChatMcp.success(
          session_id: chat_session.id,
          title: chat_session.title
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
