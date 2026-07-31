require "mcp"

module SyrusChatMcp
  class ForceLandingRecheckTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "force_landing_recheck"
    description "Request a forced landing metadata recheck for a Job, including PR checks, mergeability, commits-behind, dependency graph, and landing blocker. Requires operator confirmation."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        reason: { type: "string", description: "Operator-facing audit reason for the recheck." }
      },
      required: %w[job_id reason]
    )

    class << self
      def call(job_id:, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job_id = integer_param(job_id, "job_id")
        return job_id if job_id.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: job_id)
        return SyrusChatMcp.invalid("job not found: #{job_id}") unless job

        LandingQueueProcessor.refresh_snapshot!(Job.where(id: job.id))
        job.reload
        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "force_landing_recheck",
          payload: {
            "job_id" => job.id,
            "observed_blocker" => job.landing_queue_blocked_reason,
            "observed_state" => observed_state(job)
          },
          reason: reason,
          message: "Force landing recheck for #{job.slug}? Current blocker: #{blocker_label(job)}."
        )
      end

      private

      def observed_state(job)
        {
          "state" => job.state,
          "pr_number" => job.pr_number || job.external_pr_number,
          "pr_checks_state" => job.pr_checks_state,
          "github_mergeable_state" => job.github_mergeable_state,
          "commits_behind_base" => job.commits_behind_base,
          "landing_queue_position" => job.landing_queue_position,
          "landing_queue_entry_position" => job.landing_queue_entry_position
        }
      end

      def blocker_label(job)
        job.landing_queue_blocked_reason.to_h["key"].presence || "none"
      end
    end
  end
end
