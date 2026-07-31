require "mcp"

module Mcp::Tools
  class AdminUnpauseRunsTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "admin_unpause_runs"
    description "Request resuming Run starts globally. Requires operator confirmation."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "admin_unpause_runs",
          payload: {},
          message: "Resume runs?"
        )
      end
    end
  end
end
