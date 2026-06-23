require "mcp"

module SyrusChatMcp
  class AdminClearGithubCacheTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "admin_clear_github_cache"
    description "Request clearing the GitHub API cache. Requires operator confirmation."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        create_pending_admin_action(chat_session: chat_session, action: "admin_clear_github_cache", payload: {}, message: "Clear the GitHub API cache?")
      end
    end
  end
end
