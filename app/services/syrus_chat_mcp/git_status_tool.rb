require "mcp"

module SyrusChatMcp
  class GitStatusTool < MCP::Tool
    tool_name "git_status"

    description <<~DESC
      Show the working-tree status of the operator's local repository (git status).
      Returns which files are staged, modified, or untracked.
      Only available in Local Mode with an active daemon connection.
    DESC

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        SyrusChatMcp::LocalToolDispatch.call("git_status", {}, chat_session: chat_session)
      end
    end
  end
end
