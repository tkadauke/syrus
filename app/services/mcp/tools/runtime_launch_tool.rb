require "mcp"

module Mcp::Tools
  class RuntimeLaunchTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_launch"

    description <<~DESC
      Launch (or relaunch) the app/process/page inside a running Runtime
      Session (DOC-17) -- e.g. navigate the browser provider's page to a URL
      or path. Defaults to the chat's primary active session when
      `session_id` is omitted.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." },
        options: {
          type: "object",
          description: "Provider-specific launch options (e.g. { \"url\": ... } or { \"path\": ... } for the browser provider)."
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

        with_provider_call(session) { |provider| provider.launch(session.id, normalize_options(options)) }
      end
    end
  end
end
