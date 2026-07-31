require "mcp"

module Mcp::Tools
  class UnapproveJobTool < MCP::Tool
    extend JobLifecycleToolSupport

    tool_name "unapprove_job"

    description "Unapprove an approved Syrus Job in this chat session's repository."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to unapprove." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error
        return Mcp::Tools.invalid("job must be in approved state") unless job.approved?

        previous_state = job.state
        Job::ApprovalUnapprover.call(job: job, user: chat_session.user)

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
