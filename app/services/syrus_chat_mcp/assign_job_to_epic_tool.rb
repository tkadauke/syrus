require "mcp"

module SyrusChatMcp
  class AssignJobToEpicTool < MCP::Tool
    extend JobLifecycleToolSupport

    tool_name "assign_job_to_epic"

    description "Assign a Syrus Job to an active Epic in this chat session's repository."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to assign." },
        epic_id: { type: "integer", description: "Epic id to assign the Job to." }
      },
      required: %w[job_id epic_id]
    )

    class << self
      def call(job_id:, epic_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error

        epic, error = find_repository_epic(chat_session, epic_id)
        return error if error
        return SyrusChatMcp.invalid("epic must not be archived") if epic.archived?

        job.update!(epic_id: epic.id)

        SyrusChatMcp.success(
          job_id: job.id,
          epic_id: epic.id,
          epic_title: epic.title
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
