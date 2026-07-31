require "mcp"

module SyrusChatMcp
  class MarkCiRepairNoopTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "mark_ci_repair_noop"
    description "Record that a CI repair workflow made no effective branch/check progress and escalate the Job landing explanation. Requires operator confirmation."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        workflow_id: { type: "integer", description: "ci_failure Workflow id to mark as no-op." },
        reason: { type: "string", description: "Operator-facing audit reason." }
      },
      required: %w[job_id workflow_id reason]
    )

    class << self
      def call(job_id:, workflow_id:, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job = find_admin_job(job_id)
        return job if job.is_a?(MCP::Tool::Response)
        workflow_id = integer_param(workflow_id, "workflow_id")
        return workflow_id if workflow_id.is_a?(MCP::Tool::Response)
        workflow = job.workflows.find_by(id: workflow_id)
        return SyrusChatMcp.invalid("workflow not found for job: #{workflow_id}") unless workflow
        return SyrusChatMcp.invalid("workflow is not a ci_failure repair") unless workflow.trigger_kind == "ci_failure"

        reason = reason.to_s.strip
        return SyrusChatMcp.invalid("reason is required") if reason.empty?

        refresh = CiRepair::CheckRefresh.call(job)
        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "mark_ci_repair_noop",
          payload: {
            "job_id" => job.id,
            "workflow_id" => workflow.id,
            "observed_head_sha" => refresh.head_sha,
            "observed_pr_checks_state" => refresh.state,
            "observed_failed_checks" => refresh.failed_check_summaries
          },
          reason: reason,
          message: "Mark #{workflow.slug} as CI repair no-op for #{job.slug}? Current checks: #{refresh.state}; failing checks: #{check_labels(refresh)}."
        )
      rescue ArgumentError => e
        SyrusChatMcp.invalid(e.message)
      end

      private

      def find_admin_job(job_id)
        integer = integer_param(job_id, "job_id")
        return integer if integer.is_a?(MCP::Tool::Response)

        Job.find_by(id: integer) || SyrusChatMcp.invalid("job not found: #{integer}")
      end

      def check_labels(refresh)
        labels = refresh.failed_check_summaries.map do |check|
          name = check[:name].presence || "unknown"
          url = check[:details_url].presence
          url ? "#{name} (#{url})" : name
        end
        labels.presence&.join(", ") || "none"
      end
    end
  end
end
