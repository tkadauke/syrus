require "mcp"

module Mcp::Tools
  class BaseRefreshRetryJobTool < MCP::Tool
    extend ProposalToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "base_refresh_retry_job"
    description "Request an operator-confirmed retry from a failed Workflow's published checkpoint onto the Job's current effective base."
    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to retry." },
        source_workflow_id: { type: "integer", description: "Failed source Workflow id." },
        reason: { type: "string", description: "Why the effective base must be refreshed." }
      },
      required: %w[job_id source_workflow_id reason]
    )

    class << self
      def call(job_id:, source_workflow_id:, reason:, server_context:)
        job = find_job!(job_id)
        eligibility = BaseRefreshRetryEligibility.call(job: job, source_workflow_id: source_workflow_id)
        return Mcp::Tools.invalid(eligibility.message) unless eligibility.eligible?

        pending = create_pending_action_for_current_message!(
          server_context, server_context.fetch(:chat_session), action: "base_refresh_retry_job",
          payload: { "job_id" => job.id, "source_workflow_id" => eligibility.workflow.id, "reason" => reason.to_s.strip },
          requested_by: "agent"
        )
        Mcp::Tools.success(pending_confirmation_id: pending.id, pending_action_id: pending.id,
          state: pending.state, message: "Base refresh retry requires operator confirmation.")
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
