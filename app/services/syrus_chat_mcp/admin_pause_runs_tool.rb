require "mcp"

module SyrusChatMcp
  class AdminPauseRunsTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "admin_pause_runs"
    description "Request pausing new Run starts globally. Requires operator confirmation."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        create_pending_admin_action(chat_session: chat_session, action: "admin_pause_runs", payload: {}, message: "Pause all active runs (no new runs will start)?")
      end
    end
  end
end
