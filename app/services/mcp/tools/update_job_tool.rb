require "mcp"

module Mcp::Tools
  class UpdateJobTool < MCP::Tool
    extend JobLifecycleToolSupport

    tool_name "update_job"

    description "Update the title and/or description for a Syrus Job in this chat session's repository."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to update." },
        title: { type: "string", description: "New Job title." },
        description: { type: "string", description: "New Job body/prompt." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:, title: nil, description: nil)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error
        return Mcp::Tools.invalid("#{job.slug} is closed and cannot be updated.") if job.closed?

        attrs = {}
        attrs[:issue_title] = title if title.present?
        attrs[:issue_body] = description if description.present?
        return Mcp::Tools.invalid("title or description is required") if attrs.empty?

        job.update!(attrs)

        Mcp::Tools.success(
          job_id: job.id,
          title: job.reload.issue_title,
          description: job.issue_body,
          state: job.state
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
