require "mcp"

module Mcp::Tools
  class ApproveJobTool < MCP::Tool
    extend JobLifecycleToolSupport

    tool_name "approve_job"

    description "Approve an implemented Syrus Job in this chat session's repository."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to approve." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error
        return Mcp::Tools.invalid("job must be in implemented state") unless job.implemented?

        previous_state = job.state
        job.approve!(via: "operator", by_user: chat_session.user)

        Mcp::Tools.success(
          job_id: job.id,
          previous_state: previous_state,
          new_state: job.reload.state
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
