require "mcp"

module Mcp::Tools
  class DetachJobTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "detach_job"
    description "Diagnose, dry-run, or request an operator-confirmed repair that detaches a Job from its current stack parent and replays its owned patch onto an explicit destination base."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        destination_base: { type: "string", description: "Explicit destination branch, usually the repository default branch." },
        reason: { type: "string", description: "Concise operator-facing audit reason." },
        dry_run: { type: "boolean", default: false, description: "Return live branch, PR, parent, commit, patch, and resulting-topology evidence without creating an action." }
      },
      required: %w[job_id destination_base]
    )

    class << self
      def call(job_id:, destination_base:, reason: nil, dry_run: false, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: integer_param(job_id, "job_id"))
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job
        return Mcp::Tools.invalid("Job must have a live pull request and branch") if job.pr_number.blank? || job.branch_name.blank?
        destination_base = destination_base.to_s.strip
        return Mcp::Tools.invalid("destination_base is required") if destination_base.blank?

        plan = JobDetachPlan.for(job, destination_base: destination_base)
        return Mcp::Tools.success(plan: plan, dry_run: true) if dry_run
        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.blank?

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "detach_job",
          payload: { "job_id" => job.id, "destination_base" => destination_base, "plan" => plan },
          reason: reason,
          message: "Detach #{job.slug} from its inferred parent and restack PR ##{job.pr_number} onto #{destination_base}?",
          extra: { plan: plan }
        )
      rescue RepositoryContent::Error, Octokit::Error, ArgumentError => e
        Mcp::Tools.invalid("Could not produce a live detach plan: #{e.message}")
      end
    end
  end
end
