require "mcp"

module SyrusChatMcp
  class WriteFileTool < MCP::Tool
    tool_name "write_file"

    description <<~DESC
      Write or overwrite a file in the operator's local repository.
      The path is relative to the repository root and is sandboxed to it.
      Only available in Local Mode with an active daemon connection.
    DESC

    input_schema(
      properties: {
        path: { type: "string", description: "File path relative to the repository root." },
        content: { type: "string", description: "Full content to write to the file." }
      },
      required: %w[path content]
    )

    class << self
      def call(path:, content:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        SyrusChatMcp::LocalToolDispatch.call("write_file", { path: path, content: content }, chat_session: chat_session)
      end
    end
  end
end
