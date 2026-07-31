require "mcp"

module Mcp::Tools
  class ReopenJobTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport

    tool_name "reopen_job"

    description "Request reopening a closed Syrus Job. The Job is not reopened until the operator confirms the pending action."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to reopen." }
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
          action: "reopen_job",
          payload: { "job_id" => job.id },
          message: "Reopen #{job.slug}?"
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
