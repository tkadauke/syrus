require "mcp"

module SyrusChatMcp
  class AdminRefreshInstallationsTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "admin_refresh_installations"
    description "Request refreshing GitHub App installations. Requires operator confirmation."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        create_pending_admin_action(chat_session: chat_session, action: "admin_refresh_installations", payload: {}, message: "Refresh GitHub App installations?")
      end
    end
  end
end
