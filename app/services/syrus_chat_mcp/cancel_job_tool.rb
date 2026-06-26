require "mcp"

module SyrusChatMcp
  class CancelJobTool < MCP::Tool
    extend ProposalToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "cancel_job"

    description <<~DESC
      Request cancellation of a Syrus Job in this repository. The Job is not
      cancelled until the operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to cancel." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job_id = Integer(job_id, exception: false)
        return SyrusChatMcp.invalid("job_id is required") unless job_id

        job = find_job!(job_id)

        pending_action = create_pending_action_for_current_message!(
          server_context,
          chat_session,
          action: "cancel_job",
          payload: { "job_id" => job.id },
          requested_by: "agent"
        )

        SyrusChatMcp.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Job cancellation requires operator confirmation."
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
