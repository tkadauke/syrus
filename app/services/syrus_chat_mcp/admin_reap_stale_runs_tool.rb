require "mcp"

module SyrusChatMcp
  class AdminReapStaleRunsTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "admin_reap_stale_runs"
    description "Request an immediate stale Run reap. Requires operator confirmation."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "admin_reap_stale_runs",
          payload: {},
          message: "Force-reap all stale runs now?"
        )
      end
    end
  end
end
