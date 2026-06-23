require "mcp"

module SyrusChatMcp
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
        chat_session.update!(pinned_context: nil)

        SyrusChatMcp.success(
          pinned_context: nil,
          message: "Pinned context removed."
        )
      end
    end
  end
end
