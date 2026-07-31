require "mcp"

module Mcp::Tools
  class ListEpicsTool < MCP::Tool
    extend EpicToolSupport

    tool_name "list_epics"

    description "List Epics across all the current user's repositories from Syrus's database."

    input_schema(
      properties: {
        state: { type: "string", description: "Epic state. Omit to return all non-archived Epics." },
        limit: { type: "integer", description: "Maximum Epics to return. Defaults to 20, capped at 100." }
      }
    )

    class << self
      def call(server_context:, state: nil, limit: 20)
        chat_session = server_context.fetch(:chat_session)
        state = state.to_s.presence
        return Mcp::Tools.invalid("state must be one of #{Epic::STATES.join(", ")}") if state && !Epic::STATES.include?(state)

        repo_scope = chat_session.user.admin? ? Repository.all : chat_session.user.repositories.active
        scope = Epic.where(repository: repo_scope)
                            .left_outer_joins(:jobs)
                            .select(
                              "epics.*",
                              "COUNT(jobs.id) AS child_job_count",
                              "SUM(CASE WHEN jobs.id IS NOT NULL AND jobs.state != 'closed' THEN 1 ELSE 0 END) AS open_job_count"
                            )
                            .group("epics.id")
                            .order(created_at: :desc, id: :desc)
        scope = state ? scope.where(state: state) : scope.where.not(state: Epic::ARCHIVED_STATE)

        Mcp::Tools.success(
          epics: scope.limit(normalize_limit(limit)).map { |epic| epic_payload(epic) }
        )
      end

      private

      def normalize_limit(value)
        value.to_i.clamp(1, 100)
      end

      def epic_payload(epic)
        {
          id: epic.id,
          repository_slug: epic.repository&.slug,
          title: epic.title.to_s,
          description: truncated_description(epic),
          state: epic.state,
          child_job_count: epic.child_job_count.to_i,
          open_job_count: epic.open_job_count.to_i,
          created_at: epic.created_at&.iso8601
        }
      end
    end
  end
end
