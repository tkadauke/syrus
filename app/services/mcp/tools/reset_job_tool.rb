require "mcp"

module Mcp::Tools
  class ResetJobTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "reset_job"
    description "Request a destructive, from-scratch reset of a Job. Requires operator confirmation."
    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to reset." },
        reason: { type: "string", description: "Required operator-facing reset reason." }
      },
      required: %w[job_id reason]
    )

    class << self
      def call(job_id:, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: job_id)
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job
        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?
        eligibility = ResetJobs::Operation.preflight(job)
        return Mcp::Tools.invalid(eligibility) if eligibility

        create_pending_admin_action(
          server_context:, chat_session:, action: "reset_job", reason:,
          payload: { "job_id" => job.id }, message: "Reset #{job.slug} from scratch?",
          extra: { destroys: ResetJobs::Operation.destruction_summary(job) }
        )
      end
    end
  end
end
