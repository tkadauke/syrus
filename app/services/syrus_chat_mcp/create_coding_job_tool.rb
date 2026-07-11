require "mcp"

module SyrusChatMcp
  # Creates a new direct Job in coding state linked to this Local Mode chat.
  # Use this when the operator describes new work in local mode that doesn't
  # correspond to an existing Syrus Job.
  class CreateCodingJobTool < MCP::Tool
    tool_name "create_coding_job"

    description <<~DESC
      Create a new Syrus Job in coding state and link it to this Local Mode
      chat session. Use this when the operator describes work that doesn't
      map to an existing Job. After creation, implement using local tools,
      then call `complete_implement_step` with the pushed branch name to
      release the lock and trigger graders + PR creation.
    DESC

    input_schema(
      properties: {
        title: {
          type: "string",
          description: "Short title for the Job (used as PR title)."
        },
        body: {
          type: "string",
          description: "Description of the work to implement."
        },
        repository_id: {
          type: "integer",
          description: "Repository id to create the Job in. Defaults to the chat's attached repository if omitted."
        }
      },
      required: %w[title body]
    )

    class << self
      def call(title:, body:, repository_id: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        user = chat_session.user

        repository = if repository_id.present?
          user.repositories.active.find_by(id: Integer(repository_id, exception: false))
        else
          # Fall back to the most recently attached repository for this chat
          chat_session.chat_attachments
                      .joins("INNER JOIN repositories ON repositories.id = chat_attachments.attachable_id AND chat_attachments.attachable_type = 'Repository'")
                      .order(created_at: :desc)
                      .first&.attachable
        end

        return SyrusChatMcp.invalid("Repository not found. Specify repository_id or attach a repository to this chat.") unless repository

        job = user.jobs.new(
          repository: repository,
          kind: "direct",
          issue_title: title.strip,
          issue_body: body.strip,
          agent_provider: repository.effective_agent_provider,
          state: "coding",
          linked_chat_id: chat_session.id
        )

        unless job.save
          return SyrusChatMcp.invalid(job.errors.full_messages.to_sentence)
        end

        SyrusChatMcp.success(
          job_id: job.id,
          job_state: job.state,
          repository_slug: repository.slug,
          message: "Job #{job.id} created in coding state and linked to this chat. Implement with local tools, then call complete_implement_step."
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
