require "mcp"

module SyrusChatMcp
  class ReadEpicTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

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
        epic = find_epic!(
          id,
          includes: [
            :repository,
            { depends_on_epics: :repository },
            { dependent_epics: :repository },
            { jobs: [ :repository, { dependencies: { depends_on_job: :repository } } ] }
          ]
        )

        SyrusChatMcp.success(
          epic: epic_payload(epic),
          child_jobs: epic.jobs.order(:created_at, :id).map { |job| job_payload(job) }
        )
      end

      private

      def epic_payload(epic)
        furthest_job = epic.jobs.select(&:commits_behind_base).max_by(&:commits_behind_base)

        {
          id: epic.id,
          number: epic.number,
          display_number: epic.slug,
          title: epic.title,
          description: SyrusChatMcp.truncate_text(epic.description, 32.kilobytes),
          state: epic.state,
          repository: epic.repository.slug,
          github_issue_url: epic.github_issue_url,
          auto_approve_mode: epic.auto_approve_mode,
          depends_on_epics: epic.depends_on_epics.order(:number).map { |dependency| epic_reference(dependency) },
          dependent_epics: epic.dependent_epics.order(:number).map { |dependent| epic_reference(dependent) },
          max_commits_behind_base: furthest_job&.commits_behind_base,
          furthest_behind_job: furthest_job ? { id: furthest_job.id, slug: furthest_job.slug } : nil,
          created_at: epic.created_at&.iso8601,
          updated_at: epic.updated_at&.iso8601
        }
      end

      def epic_reference(epic)
        {
          id: epic.id,
          number: epic.number,
          display_number: epic.slug,
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
          agent_provider: job.workflow_agent_provider,
          job_provider_setting: job.job_provider_setting,
          priority: job.priority,
          issue_title: job.issue_title,
          issue_body: SyrusChatMcp.truncate_text(job.issue_body, 16.kilobytes),
          repository: job.repository.slug,
          commits_behind_base: job.commits_behind_base,
          depends_on_jobs: job.dependencies.order(:id).filter_map { |dependency| dependency_reference(dependency) },
          created_at: job.created_at&.iso8601,
          updated_at: job.updated_at&.iso8601
        }
      end

      def dependency_reference(dependency)
        if dependency.pending?
          {
            pending: true,
            unresolved_ref: dependency.unresolved_slug,
            unresolved_ref_kind: dependency.pending_reference_kind,
            unresolved_ref_state: dependency.pending_reference_state,
            source: dependency.source
          }
        elsif dependency.depends_on_job
          job_reference(dependency.depends_on_job)
        end
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
