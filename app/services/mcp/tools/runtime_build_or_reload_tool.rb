require "mcp"

module Mcp::Tools
  class RuntimeBuildOrReloadTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_build_or_reload"

    description <<~DESC
      Build or reload the target running inside a Runtime Session (DOC-17)
      -- e.g. restart a dev server, recompile, or hot-reload. Defaults to
      the chat's primary active session when `session_id` is omitted.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." },
        options: { type: "object", description: "Provider-specific build/reload options." }
      }
    )

    class << self
      def call(session_id: nil, options: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        guard = require_coding_mode(chat_session)
        return guard if guard

        session, error = resolve_runtime_session(chat_session, session_id)
        return error if error

        current = session.current_runtime_operation
        return Mcp::Tools.success(runtime_session_payload(session)) if current&.fetch("state", nil) == "active"

        lease = session.runtime_control_leases.active.held_by("agent").for_mode("build").first
        session.update!(state: "building", last_error: nil)
        operation = RuntimeSessions::Operation.new(session: session, kind: :build, lease: lease)
        result = operation.call { provider_instance_for(session).build_or_reload(session.id, normalize_options(options)) }
        return Mcp::Tools.invalid("failed to build/reload runtime session: #{result.error.message}") if result.error && !result.timed_out?
        return Mcp::Tools.invalid(result.error) if result.timed_out?

        Mcp::Tools.success(result.value)
      rescue RuntimeSessionProviders::ConfigurationError => e
        Mcp::Tools.invalid(e.message)
      rescue StandardError => e
        Mcp::Tools.invalid("failed to build/reload runtime session: #{e.message}")
      end
    end
  end
end
