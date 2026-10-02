require "mcp"

module Mcp::Tools
  class PinChatTool < MCP::Tool
    tool_name "pin_chat"

    description "Pin a chat session in the sidebar. Defaults to the current chat session."

    input_schema(
      properties: {
        chat_session_id: { type: "integer", description: "Optional chat session id. Defaults to the current chat." }
      }
    )

    class << self
      include ChatPinning

      def call(server_context:, chat_session_id: nil)
        pin_chat!(server_context: server_context, chat_session_id: chat_session_id, pinned: true)
      end
    end
  end
end
