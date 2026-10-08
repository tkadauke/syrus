require "mcp"

module Mcp::Tools
  class RuntimeSnapshotTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_snapshot"

    description <<~DESC
      Capture a point-in-time view of a Runtime Session (DOC-17), using the
      selected provider's visual snapshot path. Visual providers should return
      image metadata in the generic Runtime shape and file durable artifacts
      through the same media/artifact plumbing used by visual review. Defaults
      to the chat's primary active session when `session_id` is omitted.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." },
        options: {
          type: "object",
          description: "Provider-specific snapshot options, such as a visual target or refresh timeout."
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
