require "mcp"

module Mcp::Tools
  class CheckJobMergeabilityTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport

    tool_name "check_job_mergeability"

    description "Request a GitHub mergeability check for a Syrus Job. The check is not enqueued until the operator confirms the pending action."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to check mergeability for." }
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
          action: "check_job_mergeability",
          payload: { "job_id" => job.id },
          message: "Check mergeability for #{job.slug}?"
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
