require "mcp"

module Mcp::Tools
  class RepairQueueAffinityTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "repair_queue_affinity"
    description "Request repair of a queued Run stuck behind unsatisfied worker affinity. Requires operator confirmation."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        run_id: { type: "integer", description: "Queued Run id under this Job." },
        reason: { type: "string", description: "Operator-facing audit reason for repairing queue affinity." }
      },
      required: %w[job_id run_id reason]
    )

    class << self
      def call(job_id:, run_id:, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job_id = integer_param(job_id, "job_id")
        return job_id if job_id.is_a?(MCP::Tool::Response)
        run_id = integer_param(run_id, "run_id")
        return run_id if run_id.is_a?(MCP::Tool::Response)

        job = Job.find_by(id: job_id)
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job

        run = job.runs.find_by(id: run_id)
        return Mcp::Tools.invalid("run not found for #{job.slug}: #{run_id}") unless run

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "repair_queue_affinity",
          payload: {
            "job_id" => job.id,
            "run_id" => run.id
          },
          reason: reason,
          message: "Repair queue affinity for #{run.slug}?"
        )
      end
    end
  end
end
