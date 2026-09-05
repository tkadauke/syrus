require "mcp"

module Mcp::Tools
  class MarkCiRepairNoopTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "mark_ci_repair_noop"
    description <<~DESC
      Record that one or more CI repair workflows made no effective
      branch/check progress and escalate the Job landing explanation. Pass
      job_id/workflow_id for a single ci_failure Workflow (unchanged
      single-confirmation behavior) or workflow_ids for multiple
      ci_failure Workflows, which requires a shared reason (the root cause
      behind marking every Workflow in the batch as no-op) and creates one
      grouped pending action the operator confirms or rejects together.
      Requires operator confirmation.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id (single-item calls only)." },
        workflow_id: { type: "integer", description: "ci_failure Workflow id to mark as no-op." },
        workflow_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple ci_failure Workflow ids to mark as no-op as one grouped pending action, sharing one reason."
        },
        reason: { type: "string", description: "Operator-facing audit reason." }
      },
      required: %w[reason]
    )

    class << self
      def call(job_id: nil, workflow_id: nil, workflow_ids: nil, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        ids, bulk, error = resolve_ids(id: workflow_id, ids: workflow_ids, param_name: "workflow_id")
        return error if error

        if !bulk
          job = find_admin_job(job_id)
          return job if job.is_a?(MCP::Tool::Response)
          workflow = job.workflows.find_by(id: ids.first)
          return Mcp::Tools.invalid("workflow not found for job: #{ids.first}") unless workflow
          return Mcp::Tools.invalid("workflow is not a ci_failure repair") unless workflow.trigger_kind == "ci_failure"

          refresh = CiRepair::CheckRefresh.call(job)
          return create_pending_admin_action(
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
        end

        workflows = ids.map { |id| Workflow.find_by(id: id) }
        missing = ids.zip(workflows).select { |_id, workflow| workflow.nil? }.map(&:first)
        return Mcp::Tools.invalid("workflow not found: #{missing.join(', ')}") if missing.any?
        non_ci_failure = workflows.reject { |workflow| workflow.trigger_kind == "ci_failure" }
        return Mcp::Tools.invalid("workflow is not a ci_failure repair: #{non_ci_failure.map(&:id).join(', ')}") if non_ci_failure.any?

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: workflows.map { |workflow|
            job = workflow.job
            refresh = CiRepair::CheckRefresh.call(job)
            {
              action: "mark_ci_repair_noop",
              payload: {
                "job_id" => job.id,
                "workflow_id" => workflow.id,
                "observed_head_sha" => refresh.head_sha,
                "observed_pr_checks_state" => refresh.state,
                "observed_failed_checks" => refresh.failed_check_summaries
              },
              requested_by: "agent",
              reason: reason
            }
          },
          reason: reason
        )
        bulk_action_response(group: group, message: "Mark #{workflows.size} CI repairs as no-op?")
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def find_admin_job(job_id)
        integer = integer_param(job_id, "job_id")
        return integer if integer.is_a?(MCP::Tool::Response)

        Job.find_by(id: integer) || Mcp::Tools.invalid("job not found: #{integer}")
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
