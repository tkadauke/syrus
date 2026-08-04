require "mcp"

module SyrusChatMcp
  class RebaseJobTool < MCP::Tool
    extend ProposalToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "rebase_job"

    description <<~DESC
      Request a rebase workflow for a Syrus Job in this repository. The rebase
      workflow is not enqueued until the operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to rebase." },
        reason: { type: "string", description: "Operator-facing reason for rebasing this Job." }
      },
      required: %w[job_id reason]
    )

    class << self
      def call(job_id:, reason:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job_id = Integer(job_id, exception: false)
        return SyrusChatMcp.invalid("job_id is required") unless job_id
        reason = reason.to_s.strip
        return SyrusChatMcp.invalid("reason is required") if reason.empty?

        job = find_job!(job_id)

        pending_action = create_pending_action_for_current_message!(
          server_context,
          chat_session,
          action: "rebase_job",
          payload: { "job_id" => job.id },
          reason: reason,
          requested_by: "agent"
        )

        SyrusChatMcp.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          reason: pending_action.reason,
          message: "Job rebase requires operator confirmation."
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
