require "mcp"

module SyrusChatMcp
  class PollJobFeedbackTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport

    tool_name "poll_job_feedback"

    description "Request polling PR feedback for a Syrus Job. Polling is not enqueued until the operator confirms the pending action."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to poll for PR feedback." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = user_job(chat_session, job_id)
        return error if error

        create_pending_action!(
          server_context,
          chat_session,
          action: "poll_job_feedback",
          payload: { "job_id" => job.id },
          message: "Poll PR feedback for JOB-#{job.id}?"
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
