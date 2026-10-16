require "mcp"

module Mcp::Tools
  class RetireTerminalWorkUnitTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "retire_terminal_work_unit"
    description "Preflight and request retirement of an active WorkUnit whose Workflow is terminal, has no active Runs, and still owns locks. Preserves the Job, PR, Workflow, and audit history. Requires operator confirmation."

    input_schema(
      properties: {
        work_unit_id: { type: "integer", description: "Active WorkUnit id to inspect and retire." },
        reason: { type: "string", description: "Operator-facing audit reason." },
        dry_run: { type: "boolean", description: "Return eligibility without creating a pending action.", default: false }
      },
      required: %w[work_unit_id reason]
    )

    class << self
      def call(work_unit_id:, reason:, dry_run: false, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        id = integer_param(work_unit_id, "work_unit_id")
        return id if id.is_a?(MCP::Tool::Response)
        unit = WorkUnit.find_by(id: id)
        return Mcp::Tools.invalid("work unit not found: #{id}") unless unit

        eligibility = RepairPreflight.terminal_work_unit(work_unit: unit)
        return Mcp::Tools.success(eligibility.as_json) if dry_run
        return Mcp::Tools.invalid(eligibility.blocking_preconditions.join("; ")) unless eligibility.eligible?

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "retire_terminal_work_unit",
          payload: { "work_unit_id" => unit.id },
          reason: reason.to_s.strip,
          message: "Retire #{unit.slug} and release #{eligibility.expected_mutations[:locks]} stale lock(s)?"
        )
      end
    end
  end
end
