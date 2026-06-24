require "mcp"

module SyrusChatMcp
  class RetryJobTool < MCP::Tool
    extend ProposalToolSupport

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
        return SyrusChatMcp.invalid("job_id is required") unless job_id

        job = chat_session.repository.jobs.find_by(id: job_id)
        return SyrusChatMcp.invalid("job not found in this repository: #{job_id}") unless job

        pending_action = create_pending_action_message!(
          chat_session,
          action: "retry_job",
          payload: { "job_id" => job.id },
          requested_by: "agent"
        )

        SyrusChatMcp.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Job retry requires operator confirmation."
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
