require "mcp"

module Mcp::Tools
  class ForceRebaseTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "force_rebase"
    description <<~DESC
      Plan or request an audited rebase workflow for one or more Job PRs
      even when normal landing-queue proximity would defer it. Pass job_id
      for a single Job (unchanged single-confirmation behavior, dry_run
      supported) or job_ids for multiple Jobs sharing one
      reason/bypass_front_of_queue (the root cause behind forcing every
      rebase in the batch; dry_run is not supported for job_ids), which
      creates one grouped pending action the operator confirms or rejects
      together. Requires operator confirmation unless dry_run is true.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        job_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple Syrus Job ids to force-rebase as one grouped pending action, sharing one reason/bypass_front_of_queue. Not combinable with dry_run."
        },
        reason: { type: "string", description: "Operator-facing audit reason for forcing the rebase." },
        bypass_front_of_queue: { type: "boolean", description: "Allow this repair to run even when the Job is not near the front of the landing queue.", default: true },
        dry_run: { type: "boolean", description: "Return the planned rebase details without creating a pending action. Single job_id only.", default: false }
      },
      required: %w[]
    )

    class << self
      def call(job_id: nil, job_ids: nil, reason: nil, bypass_front_of_queue: true, dry_run: false, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        return Mcp::Tools.invalid("dry_run is only supported for a single job_id") if dry_run && job_ids.present?

        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error

        jobs = ids.map { |id| Job.find_by(id: id) }
        missing = ids.zip(jobs).select { |_id, job| job.nil? }.map(&:first)
        return Mcp::Tools.invalid("job not found: #{missing.join(', ')}") if missing.any?

        if !bulk && dry_run
          plan = JobRebasePlan.for(jobs.first, bypass_front_of_queue: bypass_front_of_queue)
          return Mcp::Tools.success(plan: plan)
        end

        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        plans = jobs.map { |job| JobRebasePlan.for(job, bypass_front_of_queue: bypass_front_of_queue) }

        unless bulk
          job = jobs.first
          plan = plans.first
          return create_pending_admin_action(
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

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: jobs.zip(plans).map { |job, plan|
            {
              action: "force_rebase",
              payload: { "job_id" => job.id, "bypass_front_of_queue" => bypass_front_of_queue != false, "plan" => plan },
              requested_by: "agent",
              reason: reason
            }
          },
          reason: reason
        )
        bulk_action_response(group: group, message: "Force rebase for #{jobs.size} Jobs?")
      end
    end
  end
end
