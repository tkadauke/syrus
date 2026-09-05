require "mcp"

module Mcp::Tools
  class ForceLandingRecheckTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "force_landing_recheck"
    description <<~DESC
      Request a forced landing metadata recheck for one or more Jobs,
      including PR checks, mergeability, commits-behind, dependency graph,
      and landing blocker. Pass job_id for a single Job (unchanged
      single-confirmation behavior) or job_ids for multiple Jobs, which
      creates one grouped pending action the operator confirms or rejects
      together. Requires operator confirmation.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        job_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple Syrus Job ids to recheck as one grouped pending action."
        },
        reason: { type: "string", description: "Operator-facing audit reason for the recheck." }
      },
      required: %w[reason]
    )

    class << self
      def call(job_id: nil, job_ids: nil, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error

        jobs = ids.map { |id| Job.find_by(id: id) }
        missing = ids.zip(jobs).select { |_id, job| job.nil? }.map(&:first)
        return Mcp::Tools.invalid("job not found: #{missing.join(', ')}") if missing.any?

        LandingQueueProcessor.refresh_snapshot!(Job.where(id: jobs.map(&:id)))
        jobs.each(&:reload)

        unless bulk
          job = jobs.first
          return create_pending_admin_action(
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

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: jobs.map { |job|
            {
              action: "force_landing_recheck",
              payload: {
                "job_id" => job.id,
                "observed_blocker" => job.landing_queue_blocked_reason,
                "observed_state" => observed_state(job)
              },
              requested_by: "agent",
              reason: reason
            }
          },
          reason: reason
        )
        bulk_action_response(group: group, message: "Force landing recheck for #{jobs.size} Jobs?")
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
