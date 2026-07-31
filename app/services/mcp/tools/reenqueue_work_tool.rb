require "mcp"

module SyrusChatMcp
  class ReenqueueWorkTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "reenqueue_work"
    description "Request safe re-enqueue of eligible queued work for a Job. Requires operator confirmation."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        workflow_id: { type: "integer", description: "Optional Workflow id under this Job." },
        run_id: { type: "integer", description: "Optional queued Run id under this Job." },
        reason: { type: "string", description: "Operator-facing audit reason for re-enqueue." }
      },
      required: %w[job_id reason]
    )

    class << self
      def call(job_id:, reason:, server_context:, workflow_id: nil, run_id: nil)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job_id = integer_param(job_id, "job_id")
        return job_id if job_id.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: job_id)
        return SyrusChatMcp.invalid("job not found: #{job_id}") unless job

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "reenqueue_work",
          payload: {
            "job_id" => job.id,
            "workflow_id" => workflow_id,
            "run_id" => run_id
          },
          reason: reason,
          message: "Re-enqueue work for #{job.slug}?"
        )
      end
    end
  end
end
