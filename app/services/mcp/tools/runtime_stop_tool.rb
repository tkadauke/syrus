require "mcp"

module Mcp::Tools
  class RuntimeStopTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_stop"

    description <<~DESC
      Tear down a Runtime Session (DOC-17): stops the underlying
      process/device/browser session and marks it stopped. Defaults to the
      chat's primary active session when `session_id` is omitted.
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

        provider = provider_instance_for(session)
        provider.stop_session(session.id)
        session.update!(state: "stopped")
        Mcp::Tools.success(runtime_session_payload(session))
      rescue RuntimeSessionProviders::ConfigurationError => e
        Mcp::Tools.invalid(e.message)
      rescue StandardError => e
        session&.update!(last_error: "#{e.class}: #{e.message}")
        Mcp::Tools.invalid("failed to stop runtime session: #{e.message}")
      end
    end
  end
end
