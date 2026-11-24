require "mcp"

module Mcp::Tools
  class HoldJobTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "hold_job"
    description <<~DESC
      Request that a Job running out of turn be held, without closing it. On
      confirmation the Job's active Runs and Workflows are cancelled through
      the normal cancellation path, its work-unit locks are released, and the
      Job returns to waiting on its unsatisfied dependencies (or to backlog
      when to_backlog is true and the Job has no PR). The Job, its PR and its
      branch are kept. Refused when the Job has no active work or when all its
      dependencies are satisfied (unless to_backlog is true). The call creates
      a pending action; confirmation revalidates these predicates.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        reason: { type: "string", description: "Operator-facing audit reason, e.g. which dependency the Job is running ahead of." },
        to_backlog: { type: "boolean", description: "Park the Job in backlog instead of waiting on dependencies. Not available for Jobs that already have a PR. Defaults to false." }
      },
      required: %w[job_id reason]
    )

    class << self
      def call(job_id:, reason:, server_context:, to_backlog: false)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        job_id = integer_param(job_id, "job_id")
        return job_id if job_id.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: job_id)
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job

        blockers = JobHold.blockers(job, to_backlog: to_backlog == true)
        return Mcp::Tools.invalid(blockers.join("; ")) if blockers.any?

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "hold_job",
          payload: { "job_id" => job.id, "to_backlog" => to_backlog == true },
          reason: reason,
          message: I18n.t("server.mcp.hold_job_confirmation.message", job: job.slug)
        )
      end
    end
  end
end
