require "mcp"

module Mcp::Tools
  class AdminKillProcessTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "admin_kill_process"
    description "Request a kill signal for a running SpawnedProcess. Requires operator confirmation."

    input_schema(
      properties: {
        process_id: { type: "integer", description: "SpawnedProcess id to kill." }
      },
      required: %w[process_id]
    )

    class << self
      def call(process_id:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        process_id = integer_param(process_id, "process_id")
        return process_id if process_id.is_a?(MCP::Tool::Response)

        process = SpawnedProcess.find_by(id: process_id)
        return Mcp::Tools.invalid("process not found: #{process_id}") unless process

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "admin_kill_process",
          payload: { "process_id" => process.id },
          message: "Kill process ##{process.id} (#{process.kind} on #{process.hostname})?"
        )
      end
    end
  end
end
