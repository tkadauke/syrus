require "mcp"

module Mcp::Tools
  class RuntimeLogsTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_logs"

    description <<~DESC
      Return the next chunk of log output from a Runtime Session (DOC-17)
      after `cursor`. Pass the `cursor` a previous call returned to page
      forward. Defaults to the chat's primary active session when
      `session_id` is omitted.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." },
        cursor: { description: "Opaque cursor from a previous runtime_logs call. Defaults to the beginning." },
        limit: { type: "integer", description: "Maximum number of log entries to return, if the provider supports it." }
      }
    )

    class << self
      def call(session_id: nil, cursor: nil, limit: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        guard = require_coding_mode(chat_session)
        return guard if guard

        session, error = resolve_runtime_session(chat_session, session_id)
        return error if error

        with_provider_call(session) { |provider| provider.logs(session.id, cursor.presence || 0, { limit: limit }.compact) }
      end
    end
  end
end
