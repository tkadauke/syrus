require "mcp"

module Mcp::Tools
  class RemoveJobFromEpicTool < MCP::Tool
    extend JobLifecycleToolSupport

    tool_name "remove_job_from_epic"

    description "Remove a Syrus Job from its Epic in this chat session's repository."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to remove from its Epic." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error
        return Mcp::Tools.invalid("job must currently belong to an epic") unless job.epic_id

        removed_epic = job.epic
        job.update!(epic_id: nil)

        Mcp::Tools.success(
          job_id: job.id,
          removed_from_epic_id: removed_epic.id,
          removed_from_epic_title: removed_epic.title
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
