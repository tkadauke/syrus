require "mcp"

module Mcp::Tools
  class RetireTerminalWorkUnitTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "retire_terminal_work_unit"
    description "Preflight and request retirement of an active WorkUnit whose Workflow is terminal, has no active Runs, and still owns locks. Preserves the Job, PR, Workflow, and audit history. Requires operator confirmation."

    input_schema(
      properties: {
        work_unit_id: { type: "integer", description: "Active WorkUnit id to inspect and retire." },
        work_unit_ids: { type: "array", items: { type: "integer" }, maxItems: BulkPendingActionToolSupport::MAX_BATCH_SIZE, description: "Multiple WorkUnit ids to retire as one grouped pending action." },
        reason: { type: "string", description: "Operator-facing audit reason." },
        dry_run: { type: "boolean", description: "Return eligibility without creating a pending action.", default: false }
      },
      required: %w[reason]
    )

    class << self
      def call(work_unit_id: nil, work_unit_ids: nil, reason:, dry_run: false, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        ids, bulk, error = resolve_ids(id: work_unit_id, ids: work_unit_ids, param_name: "work_unit_id")
        return error if error
        units = ids.map { |id| WorkUnit.find_by(id: id) }
        missing = ids.zip(units).filter_map { |id, unit| id unless unit }
        return Mcp::Tools.invalid("work unit not found: #{missing.join(', ')}") if missing.any?

        eligibilities = units.map { |unit| RepairPreflight.terminal_work_unit(work_unit: unit) }
        return Mcp::Tools.success(results: eligibilities.map(&:as_json), dry_run: true) if dry_run && bulk
        return Mcp::Tools.success(eligibilities.first.as_json) if dry_run
        blocked = units.zip(eligibilities).filter_map { |unit, eligibility| "#{unit.slug}: #{eligibility.blocking_preconditions.join('; ')}" unless eligibility.eligible? }
        return Mcp::Tools.invalid(blocked.join(" | ")) if blocked.any?

        unless bulk
          unit = units.first
          eligibility = eligibilities.first
          return create_pending_admin_action(
            server_context: server_context, chat_session: chat_session, action: "retire_terminal_work_unit",
            payload: { "work_unit_id" => unit.id }, reason: reason.to_s.strip,
            message: "Retire #{unit.slug} and release #{eligibility.expected_mutations[:locks]} stale lock(s)?"
          )
        end

        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?
        group = create_pending_action_group!(server_context:, chat_session:, reason:, member_attributes: units.map { |unit|
          { action: "retire_terminal_work_unit", payload: { "work_unit_id" => unit.id }, requested_by: "agent", reason: reason }
        })
        bulk_action_response(group:, message: I18n.t("server.mcp.bulk_confirmation.retire_work_units", count: units.size))
      end
    end
  end
end
