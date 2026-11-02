require "mcp"

module Mcp::Tools
  class RuntimeInspectTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_inspect"

    description <<~DESC
      Return a structural inspection of a Runtime Session's target (DOC-17)
      using the selected provider's supported inspection mode, such as an
      accessibility tree, native UI hierarchy, or authoritative terminal
      screen. Screen-oriented providers support screen/scrollback modes and bounded
      generation, visible-text, screen-change, and quiet-period waits. Defaults
      to the chat's primary active session when `session_id` is omitted.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." },
        options: {
          type: "object",
          description: "Provider-specific inspect options. Screen-oriented sessions support mode, include_styles, after_generation, wait_for_change, wait_for_text, quiet_ms, and timeout_ms.",
          properties: {
            mode: { type: "string", enum: %w[screen scrollback] },
            include_styles: { type: "boolean" },
            after_generation: { type: "integer", minimum: 0 },
            wait_for_change: { type: "boolean" },
            wait_for_text: { type: "string" },
            quiet_ms: { type: "number", minimum: 0 },
            timeout_ms: { type: "number", minimum: 0, maximum: 30_000 }
          }
        }
      }
    )

    class << self
      def call(session_id: nil, options: nil, server_context:)
        owner, guard = runtime_owner_from(server_context)
        return guard if guard

        session, error = resolve_runtime_session(owner, session_id)
        return error if error

        with_provider_call(session) { |provider| provider.inspect(session.id, normalize_options(options)) }
      end
    end
  end
end
