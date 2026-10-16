require "mcp"

module Mcp::Tools
  class RetireTerminalWorkUnitTool < MCP::Tool
    extend AdminPendingActionToolSupport
    tool_name "retire_terminal_work_unit"
    description "Preflight or request retirement of a nonterminal WorkUnit that still owns locks after its Workflow became terminal. Preserves Job, PR, Workflow, and audit records."
    input_schema(properties: { work_unit_id: { type: "integer" }, dry_run: { type: "boolean", default: false }, reason: { type: "string" } }, required: %w[work_unit_id])

    class << self
      def call(work_unit_id:, server_context:, dry_run: false, reason: nil)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)
        id = integer_param(work_unit_id, "work_unit_id")
        return id if id.is_a?(MCP::Tool::Response)
        unit = WorkUnit.find_by(id: id)
        return Mcp::Tools.invalid("work unit not found: #{id}") unless unit
        plan = WorkUnits::TerminalLockCleanup.preflight(unit)
        return Mcp::Tools.success(outcome: plan.eligible? ? "noop" : "rejected", preflight: plan.as_json) if dry_run
        return Mcp::Tools.invalid(plan.rejection_message) unless plan.eligible?
        return Mcp::Tools.invalid("reason is required") if reason.to_s.strip.empty?

        create_pending_admin_action(server_context: server_context, chat_session: chat_session, action: "retire_terminal_work_unit", payload: { "job_id" => unit.workflow.job_id, "work_unit_id" => unit.id, "preflight" => plan.as_json }, reason: reason.to_s.strip, message: "Retire #{unit.slug}, releasing #{plan.target[:lock_keys].join(', ')} while preserving Workflow #{unit.workflow_id}?")
      end
    end
  end
end
