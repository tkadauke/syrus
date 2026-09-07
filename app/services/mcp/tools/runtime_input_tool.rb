require "mcp"

module Mcp::Tools
  class RuntimeInputTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_input"

    description <<~DESC
      Deliver an input event (pointer, keyboard, touch, stdin, ...) to a
      Runtime Session's target (DOC-17). The provider enforces DOC-17's
      shared-control lease: this fails with `lease_required` unless the
      agent currently holds an active "input" mode runtime_acquire_control
      lease on this session. Defaults to the chat's primary active session
      when `session_id` is omitted.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." },
        event: {
          type: "object",
          description: "Provider-specific input event payload (e.g. { \"type\": \"click\", \"target\": \"e3\" })."
        }
      },
      required: %w[event]
    )

    class << self
      def call(event:, session_id: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        guard = require_coding_mode(chat_session)
        return guard if guard

        return Mcp::Tools.invalid("event must be an object") unless event.is_a?(Hash)

        session, error = resolve_runtime_session(chat_session, session_id)
        return error if error

        with_provider_call(session) { |provider| provider.input(session.id, event) }
      end
    end
  end
end
