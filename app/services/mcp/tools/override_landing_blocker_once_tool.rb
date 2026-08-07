require "mcp"

module Mcp::Tools
  class OverrideLandingBlockerOnceTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "override_landing_blocker_once"
    description "Request a single audited landing attempt past the current landing blocker key for a Job. Requires operator confirmation and cannot bypass missing PRs, failed required checks, or pending checks."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        blocker_key: { type: "string", description: "Exact current landing blocker key to bypass once." },
        reason: { type: "string", description: "Operator-facing audit reason for the override." }
      },
      required: %w[job_id blocker_key reason]
    )

    class << self
      def call(job_id:, blocker_key:, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job_id = integer_param(job_id, "job_id")
        return job_id if job_id.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: job_id)
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job

        LandingQueueProcessor.refresh_snapshot!(Job.where(id: job.id))
        job.reload
        current_key = job.landing_queue_blocked_reason.to_h["key"].to_s
        return Mcp::Tools.invalid("current blocker is #{current_key.presence || 'none'}, not #{blocker_key}") unless current_key == blocker_key.to_s
        return Mcp::Tools.invalid("#{blocker_key} cannot be bypassed by this tool") unless LandingBlockerOverride.overridable?(blocker_key)

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "override_landing_blocker_once",
          payload: {
            "job_id" => job.id,
            "blocker_key" => blocker_key.to_s,
            "observed_blocker" => job.landing_queue_blocked_reason,
            "observed_state" => observed_state(job)
          },
          reason: reason,
          message: "Override #{blocker_key} once for #{job.slug}? Refreshed state is included in the pending action."
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
    end
  end
end
