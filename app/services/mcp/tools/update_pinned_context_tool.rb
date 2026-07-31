require "mcp"

module Mcp::Tools
  class UpdatePinnedContextTool < MCP::Tool
    tool_name "update_pinned_context"

    description <<~DESC
      Update this chat session's pinned context. The pinned context is
      included near the top of future chat system prompts for this session.
    DESC

    input_schema(
      properties: {
        content: { type: "string", description: "Pinned context to include in future chat turns." }
      },
      required: %w[content]
    )

    class << self
      def call(content:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        content = content.to_s
        return Mcp::Tools.invalid("content is required") if content.blank?

        chat_session.update!(pinned_context: content)

        Mcp::Tools.success(
          pinned_context: chat_session.pinned_context,
          message: "Pinned context updated."
        )
      end
    end
  end
end
