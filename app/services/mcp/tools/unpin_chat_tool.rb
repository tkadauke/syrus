require "mcp"

module Mcp::Tools
  class UnpinChatTool < MCP::Tool
    tool_name "unpin_chat"

    description "Unpin a chat session from the sidebar. Defaults to the current chat session."

    input_schema(
      properties: {
        chat_session_id: { type: "integer", description: "Optional chat session id. Defaults to the current chat." }
      }
    )

    class << self
      include ChatPinning

      def call(server_context:, chat_session_id: nil)
        pin_chat!(server_context: server_context, chat_session_id: chat_session_id, pinned: false)
      end
    end
  end
end
