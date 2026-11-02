require "mcp"

module Mcp::Tools
  class RuntimeReleaseControlTool < MCP::Tool
    extend RuntimeSessionToolSupport

    tool_name "runtime_release_control"

    description <<~DESC
      Release the agent's active Runtime Control Lease(s) (DOC-17) on a
      Runtime Session, returning input/build/lifecycle control to the
      operator. A no-op (returns an empty list) when the agent holds no
      active lease.
    DESC

    input_schema(
      properties: {
        session_id: { description: "Runtime Session id. Defaults to the chat's primary active session." }
      }
    )

    class << self
      def call(session_id: nil, server_context:)
        owner, guard = runtime_owner_from(server_context)
        return guard if guard

        session, error = resolve_runtime_session(owner, session_id)
        return error if error

        released = session.runtime_control_leases.active.held_by("agent").map(&:release!)

        Mcp::Tools.success(released: released.map { |lease| lease_payload(lease) })
      end
    end
  end
end
