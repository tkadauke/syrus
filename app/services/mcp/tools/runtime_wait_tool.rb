require "mcp"

module Mcp::Tools
  class RuntimeWaitTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_wait"

    description <<~DESC
      Wait for a provider-neutral Runtime Session condition, such as visible
      text, a changed frame/screen generation, or a quiet period. Returns the
      provider's structural inspection when the condition is satisfied.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the current primary session." },
        text: { type: "string", description: "Optional visible text to wait for." },
        after_generation: { type: "integer", minimum: 0 },
        quiet_ms: { type: "number", minimum: 0 },
        timeout_ms: { type: "number", minimum: 0, maximum: 30_000 }
      }
    )

    class << self
      def call(session_id: nil, text: nil, after_generation: nil, quiet_ms: nil, timeout_ms: 5_000, server_context:)
        owner, guard = runtime_owner_from(server_context)
        return guard if guard

        session, error = resolve_runtime_session(owner, session_id)
        return error if error

        options = {
          wait_for_text: text,
          after_generation: after_generation,
          wait_for_change: after_generation.present?,
          quiet_ms: quiet_ms,
          timeout_ms: timeout_ms
        }.compact
        with_provider_call(session) { |provider| provider.inspect(session.id, options) }
      end
    end
  end
end
