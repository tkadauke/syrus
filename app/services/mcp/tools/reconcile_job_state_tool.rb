require "mcp"

module Mcp::Tools
  class ReconcileJobStateTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "reconcile_job_state"
    description <<~DESC
      Request a targeted Job state reconciliation. Pass job_id for a single
      Job (unchanged single-confirmation behavior, any mode) or job_ids for
      multiple Jobs, which requires mode: auto (the constrained explicit
      modes stay single-item) and a shared reason (the root cause behind
      reconciling every Job in the batch), and creates one grouped pending
      action the operator confirms or rejects together. Requires operator
      confirmation.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to reconcile." },
        job_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple Syrus Job ids to reconcile with mode: auto as one grouped pending action, sharing one reason."
        },
        mode: {
          type: "string",
          enum: PendingActions::ReconcileJobState::MODES,
          description: "Use auto for the WorkEngine reconciler, or a constrained explicit reconciliation (job_id only)."
        },
        reason: { type: "string", description: "Operator-facing audit reason for the repair." }
      },
      required: %w[mode reason]
    )

    class << self
      def call(job_id: nil, job_ids: nil, mode:, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        return Mcp::Tools.invalid("job_ids reconciliation is only supported for mode: auto") if job_ids.present? && mode.to_s != "auto"

        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error

        jobs = ids.map { |id| Job.find_by(id: id) }
        missing = ids.zip(jobs).select { |_id, job| job.nil? }.map(&:first)
        return Mcp::Tools.invalid("job not found: #{missing.join(', ')}") if missing.any?

        unless bulk
          job = jobs.first
          return create_pending_admin_action(
            server_context: server_context,
            chat_session: chat_session,
            action: "reconcile_job_state",
            payload: { "job_id" => job.id, "mode" => mode.to_s },
            reason: reason,
            message: "Reconcile #{job.slug} using mode #{mode}?"
          )
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: jobs.map { |job|
            { action: "reconcile_job_state", payload: { "job_id" => job.id, "mode" => "auto" }, requested_by: "agent", reason: reason }
          },
          reason: reason
        )
        bulk_action_response(group: group, message: "Reconcile #{jobs.size} Jobs using mode auto?")
      end
    end
  end
end
