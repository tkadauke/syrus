require "mcp"

module Mcp::Tools
  class ReadFileTool < MCP::Tool
    tool_name "read_file"

    description <<~DESC
      Read a file from the operator's local repository.
      The path is relative to the repository root and is sandboxed to it.
      Only available in Local Mode with an active daemon connection.
    DESC

    input_schema(
      properties: {
        path: { type: "string", description: "File path relative to the repository root." }
      },
      required: %w[path]
    )

    class << self
      def call(path:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        Mcp::Tools::LocalToolDispatch.call("read_file", { path: path }, chat_session: chat_session)
      end
    end
  end
end
