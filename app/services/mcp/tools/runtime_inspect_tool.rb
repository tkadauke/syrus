require "mcp"

module Mcp::Tools
  class RuntimeInspectTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_inspect"

    description <<~DESC
      Return a structural inspection of a Runtime Session's target (DOC-17)
      -- for the browser provider, an accessibility-tree snapshot delegated
      to the same context-aware browser_snapshot tool implementation visual
      review uses. Defaults to the chat's primary active session when
      `session_id` is omitted.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." },
        options: { type: "object", description: "Provider-specific inspect options." }
      }
    )

    class << self
      def call(session_id: nil, options: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        guard = require_coding_mode(chat_session)
        return guard if guard

        session, error = resolve_runtime_session(chat_session, session_id)
        return error if error

        with_provider_call(session) { |provider| provider.inspect(session.id, normalize_options(options)) }
      end
    end
  end
end
