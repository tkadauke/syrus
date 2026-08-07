require "mcp"

module Mcp::Tools
  class ForceRebaseTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "force_rebase"
    description "Plan or request an audited rebase workflow for a Job PR even when normal landing-queue proximity would defer it. Requires operator confirmation unless dry_run is true."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        reason: { type: "string", description: "Operator-facing audit reason for forcing the rebase." },
        bypass_front_of_queue: { type: "boolean", description: "Allow this repair to run even when the Job is not near the front of the landing queue.", default: true },
        dry_run: { type: "boolean", description: "Return the planned rebase details without creating a pending action.", default: false }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, reason: nil, bypass_front_of_queue: true, dry_run: false, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job_id = integer_param(job_id, "job_id")
        return job_id if job_id.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: job_id)
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job

        plan = JobRebasePlan.for(job, bypass_front_of_queue: bypass_front_of_queue)
        return Mcp::Tools.success(plan: plan) if dry_run

        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "force_rebase",
          payload: {
            "job_id" => job.id,
            "bypass_front_of_queue" => bypass_front_of_queue != false,
            "plan" => plan
          },
          reason: reason,
          message: "Force #{plan.fetch("workflow_trigger_kind")} for #{job.slug}? Target base: #{plan.fetch("target_base") || "unknown"}."
        )
      end
    end
  end
end
