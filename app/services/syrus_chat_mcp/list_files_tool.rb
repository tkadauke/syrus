require "mcp"

module SyrusChatMcp
  class ListFilesTool < MCP::Tool
    tool_name "list_files"

    description <<~DESC
      List files in a directory within the operator's local repository.
      The path is relative to the repository root and is sandboxed to it.
      Omit path or pass "." to list the repository root.
      Only available in Local Mode with an active daemon connection.
    DESC

    input_schema(
      properties: {
        path: { type: "string", description: "Directory path relative to the repository root. Defaults to the repository root." }
      }
    )

    class << self
      def call(server_context:, path: ".")
        chat_session = server_context.fetch(:chat_session)
        SyrusChatMcp::LocalToolDispatch.call("list_files", { path: path }, chat_session: chat_session)
      end
    end
  end
end
