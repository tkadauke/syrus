require "mcp"

module Mcp::Tools
  class CancelStaleWorkTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "cancel_stale_work"
    description "Request cancellation of stale queued/running Workflows or Runs for a Job. Requires operator confirmation."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        workflow_ids: { type: "array", items: { type: "integer" }, description: "Optional Workflow ids under this Job to cancel." },
        run_ids: { type: "array", items: { type: "integer" }, description: "Optional Run ids under this Job to cancel." },
        reconcile: { type: "boolean", description: "Run targeted WorkEngine reconciliation after cancellation. Defaults to true." },
        reason: { type: "string", description: "Operator-facing audit reason for cancellation." }
      },
      required: %w[job_id reason]
    )

    class << self
      def call(job_id:, reason:, server_context:, workflow_ids: nil, run_ids: nil, reconcile: true)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job_id = integer_param(job_id, "job_id")
        return job_id if job_id.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: job_id)
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "cancel_stale_work",
          payload: {
            "job_id" => job.id,
            "workflow_ids" => normalize_integer_list(workflow_ids),
            "run_ids" => normalize_integer_list(run_ids),
            "reconcile" => reconcile.nil? ? true : !!reconcile
          },
          reason: reason,
          message: "Cancel stale work for #{job.slug}?"
        )
      end
    end
  end
end
