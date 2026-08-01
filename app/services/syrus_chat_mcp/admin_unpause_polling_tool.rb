require "mcp"

module SyrusChatMcp
  class AdminUnpausePollingTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "admin_unpause_polling"
    description "Request resuming repository polling globally. Requires operator confirmation."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "admin_unpause_polling",
          payload: {},
          message: "Resume repository polling?"
        )
      end
    end
  end
end
