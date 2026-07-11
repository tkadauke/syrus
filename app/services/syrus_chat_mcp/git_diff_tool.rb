require "mcp"

module SyrusChatMcp
  class GitDiffTool < MCP::Tool
    tool_name "git_diff"

    description <<~DESC
      Show uncommitted changes in the operator's local repository (git diff).
      Returns the diff of staged and unstaged changes against HEAD.
      Only available in Local Mode with an active daemon connection.
    DESC

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        SyrusChatMcp::LocalToolDispatch.call("git_diff", {}, chat_session: chat_session)
      end
    end
  end
end
