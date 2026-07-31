require "mcp"

module Mcp::Tools
  class RemoveJobTagTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "remove_job_tag"

    description "Remove a user-owned tag from a Job in this chat session's repository."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        tag_id: { type: "integer", description: "Tag id." }
      },
      required: %w[job_id tag_id]
    )

    class << self
      def call(job_id:, tag_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job = find_job!(job_id)

        tag = chat_session.user.tags.find_by(id: tag_id)
        return Mcp::Tools.invalid("tag not found for this user: #{tag_id}") unless tag

        job.job_tags.where(tag: tag).destroy_all
        broadcast_job_update(chat_session.user, job)
        Mcp::Tools.success(success: true)
      end

      private

      def broadcast_job_update(user, job)
        AppEvents.broadcast(user: user, type: "updated", resource: "job", id: job.id, changed: [ "tags" ])
      end
    end
  end
end
