require "mcp"

module Mcp::Tools
  class AdminKillProcessTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "admin_kill_process"
    description <<~DESC
      Request a kill signal for one or more running SpawnedProcesses. Pass
      process_id for a single process (unchanged single-confirmation
      behavior) or process_ids for multiple processes, which creates one
      grouped pending action the operator confirms or rejects together.
      Requires operator confirmation.
    DESC

    input_schema(
      properties: {
        process_id: { type: "integer", description: "SpawnedProcess id to kill." },
        process_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple SpawnedProcess ids to kill as one grouped pending action."
        }
      }
    )

    class << self
      def call(process_id: nil, process_ids: nil, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        ids, bulk, error = resolve_ids(id: process_id, ids: process_ids, param_name: "process_id")
        return error if error

        processes = ids.map { |id| SpawnedProcess.find_by(id: id) }
        missing = ids.zip(processes).select { |_id, process| process.nil? }.map(&:first)
        return Mcp::Tools.invalid("process not found: #{missing.join(', ')}") if missing.any?

        unless bulk
          process = processes.first
          return create_pending_admin_action(
            server_context: server_context,
            chat_session: chat_session,
            action: "admin_kill_process",
            payload: { "process_id" => process.id },
            message: "Kill process ##{process.id} (#{process.kind} on #{process.hostname})?"
          )
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: processes.map { |process| { action: "admin_kill_process", payload: { "process_id" => process.id }, requested_by: "agent" } }
        )
        bulk_action_response(group: group, message: "Kill #{processes.size} processes?")
      end
    end
  end
end
