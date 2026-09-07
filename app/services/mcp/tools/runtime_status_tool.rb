require "mcp"

module Mcp::Tools
  class RuntimeStatusTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_status"

    description <<~DESC
      Report the current state of a Runtime Session (DOC-17): lifecycle
      state, capabilities, latest frame/stream info, and its active control
      lease, if any. Defaults to the chat's primary active session when
      `session_id` is omitted.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." }
      }
    )

    class << self
      def call(session_id: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        guard = require_coding_mode(chat_session)
        return guard if guard

        session, error = resolve_runtime_session(chat_session, session_id)
        return error if error

        Mcp::Tools.success(runtime_session_payload(session))
      end
    end
  end
end
