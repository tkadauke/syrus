require "mcp"

module SyrusChatMcp
  class AddJobTagTool < MCP::Tool
    tool_name "add_job_tag"

    description "Attach a user-owned tag to a Job in this chat session's repository."

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
        job = find_job(chat_session, job_id)
        return SyrusChatMcp.invalid("job not found in this repository: #{job_id}") unless job

        tag = chat_session.user.tags.find_by(id: tag_id)
        return SyrusChatMcp.invalid("tag not found for this user: #{tag_id}") unless tag

        job.job_tags.find_or_create_by!(tag: tag)
        broadcast_job_update(chat_session.user, job)
        SyrusChatMcp.success(success: true)
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def find_job(chat_session, job_id)
        repository = chat_session.repository
        return unless repository

        repository.jobs.find_by(id: job_id)
      end

      def broadcast_job_update(user, job)
        AppEvents.broadcast(user: user, type: "updated", resource: "job", id: job.id, changed: [ "tags" ])
      end
    end
  end
end
