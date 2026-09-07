require "mcp"

module Mcp::Tools
  class RuntimeSnapshotTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_snapshot"

    description <<~DESC
      Capture a point-in-time view of a Runtime Session (DOC-17) -- for the
      browser provider, a screenshot delegated to the same context-aware
      browser_screenshot tool implementation and ArtifactSink resolution
      visual review uses, so it also files as chat media in Coding Mode.
      Defaults to the chat's primary active session when `session_id` is
      omitted.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." },
        options: {
          type: "object",
          description: "Provider-specific snapshot options (e.g. { \"target\": \"e1\" } to screenshot one element for the browser provider)."
        }
      }
    )

    class << self
      def call(session_id: nil, options: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        guard = require_coding_mode(chat_session)
        return guard if guard

        session, error = resolve_runtime_session(chat_session, session_id)
        return error if error

        with_provider_call(session) { |provider| provider.snapshot(session.id, normalize_options(options)) }
      end
    end
  end
end
