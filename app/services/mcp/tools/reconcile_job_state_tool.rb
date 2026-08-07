require "mcp"

module Mcp::Tools
  class ReconcileJobStateTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "reconcile_job_state"
    description "Request a targeted Job state reconciliation. Requires operator confirmation."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to reconcile." },
        mode: {
          type: "string",
          enum: PendingActions::ReconcileJobState::MODES,
          description: "Use auto for the WorkEngine reconciler, or a constrained explicit reconciliation."
        },
        reason: { type: "string", description: "Operator-facing audit reason for the repair." }
      },
      required: %w[job_id mode reason]
    )

    class << self
      def call(job_id:, mode:, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job_id = integer_param(job_id, "job_id")
        return job_id if job_id.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: job_id)
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "reconcile_job_state",
          payload: { "job_id" => job.id, "mode" => mode.to_s },
          reason: reason,
          message: "Reconcile #{job.slug} using mode #{mode}?"
        )
      end
    end
  end
end
