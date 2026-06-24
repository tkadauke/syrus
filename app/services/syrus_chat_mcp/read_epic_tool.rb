require "mcp"

module SyrusChatMcp
  class ReadEpicTool < MCP::Tool
    tool_name "read_epic"

    description <<~DESC
      Read an Epic visible to this chat session's user, including its description,
      dependencies, dependent Epics, and child Jobs.
    DESC

    input_schema(
      properties: {
        id: { type: "integer", description: "Epic id to inspect." }
      },
      required: %w[id]
    )

    class << self
      def call(id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        epic = chat_session.user.epics
                           .includes(
                             :repository,
                             depends_on_epics: :repository,
                             dependent_epics: :repository,
                             jobs: [ :repository, { depends_on_jobs: :repository } ]
                           )
                           .find_by(id: id)
        return SyrusChatMcp.invalid("epic not found or not readable: #{id}") unless epic

        SyrusChatMcp.success(
          epic: epic_payload(epic),
          child_jobs: epic.jobs.order(:created_at, :id).map { |job| job_payload(job) }
        )
      end

      private

      def epic_payload(epic)
        {
          id: epic.id,
          number: epic.number,
          display_number: epic.display_number,
          title: epic.title,
          description: SyrusChatMcp.truncate_text(epic.description, 32.kilobytes),
          state: epic.state,
          repository: epic.repository.slug,
          github_issue_url: epic.github_issue_url,
          auto_approve_mode: epic.auto_approve_mode,
          depends_on_epics: epic.depends_on_epics.order(:number).map { |dependency| epic_reference(dependency) },
          dependent_epics: epic.dependent_epics.order(:number).map { |dependent| epic_reference(dependent) },
          created_at: epic.created_at&.iso8601,
          updated_at: epic.updated_at&.iso8601
        }
      end

      def epic_reference(epic)
        {
          id: epic.id,
          number: epic.number,
          display_number: epic.display_number,
          title: epic.title,
          state: epic.state,
          repository: epic.repository.slug
        }
      end

      def job_payload(job)
        {
          id: job.id,
          kind: job.kind,
          issue_number: job.issue_number,
          pr_number: job.pr_number || job.external_pr_number,
          internal_pr_number: job.pr_number,
          external_pr_number: job.external_pr_number,
          branch_name: job.branch_name,
          state: job.state,
          closure_reason: job.closure_reason,
          agent_provider: job.agent_provider,
          priority: job.priority,
          issue_title: job.issue_title,
          issue_body: SyrusChatMcp.truncate_text(job.issue_body, 16.kilobytes),
          repository: job.repository.slug,
          depends_on_jobs: job.depends_on_jobs.order(:id).map { |dependency| job_reference(dependency) },
          created_at: job.created_at&.iso8601,
          updated_at: job.updated_at&.iso8601
        }
      end

      def job_reference(job)
        {
          id: job.id,
          issue_number: job.issue_number,
          issue_title: job.issue_title,
          state: job.state,
          repository: job.repository.slug
        }
      end
    end
  end
end
