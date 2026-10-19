require "mcp"

module Mcp::Tools
  class RemovePinnedContextTool < MCP::Tool
    tool_name "remove_pinned_context"

    description <<~DESC
      Remove this chat session's pinned context from future chat system prompts.
    DESC

    input_schema(
      properties: {}
    )

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        removed_pinned_context = chat_session.pinned_context
        chat_session.update!(pinned_context: nil)

        Mcp::Tools.success(
          chat_id: chat_session.id,
          pinned_context: nil,
          removed_pinned_context: removed_pinned_context,
          message: "Pinned context removed."
        )
      end
    end
  end
end
