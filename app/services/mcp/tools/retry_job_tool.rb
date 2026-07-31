require "mcp"

module Mcp::Tools
  class RetryJobTool < MCP::Tool
    extend ProposalToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "retry_job"

    description <<~DESC
      Request a retry workflow for a Syrus Job in this repository. The retry
      workflow is not enqueued until the operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to retry." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job_id = Integer(job_id, exception: false)
        return Mcp::Tools.invalid("job_id is required") unless job_id

        job = find_job!(job_id)

        pending_action = create_pending_action_for_current_message!(
          server_context,
          chat_session,
          action: "retry_job",
          payload: { "job_id" => job.id },
          requested_by: "agent"
        )

        Mcp::Tools.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Job retry requires operator confirmation."
        )
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
