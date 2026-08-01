require "mcp"

module SyrusChatMcp
  class AdminPausePollingTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "admin_pause_polling"
    description "Request pausing repository polling globally. Requires operator confirmation."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "admin_pause_polling",
          payload: {},
          message: "Pause all repository polling?"
        )
      end
    end
  end
end
