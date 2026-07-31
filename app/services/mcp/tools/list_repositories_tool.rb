require "mcp"

module Mcp::Tools
  class ListRepositoriesTool < MCP::Tool
    tool_name "list_repositories"

    description "List the current operator's active repositories connected to Syrus."

    input_schema(
      properties: {
        page: { type: "integer", description: "1-based page number. Defaults to 1." },
        per_page: { type: "integer", description: "Repositories per page. Defaults to 20, capped at 100." }
      }
    )

    class << self
      def call(server_context:, page: 1, per_page: 20)
        chat_session = server_context.fetch(:chat_session)
        page = normalize_page(page)
        per_page = normalize_per_page(per_page)
        scope = chat_session.user.admin? ? Repository.active.order(:owner, :name, :id) : chat_session.user.repositories.active.order(:owner, :name, :id)
        total_count = scope.count
        repositories = scope.offset((page - 1) * per_page).limit(per_page)

        Mcp::Tools.success(
          repositories: repositories.map { |repository| payload_for(repository) },
          pagination: {
            page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: (total_count.to_f / per_page).ceil,
            has_next_page: page * per_page < total_count
          }
        )
      end

      private

      def normalize_page(value)
        [ value.to_i, 1 ].max
      end

      def normalize_per_page(value)
        value.to_i.clamp(1, 100)
      end

      def payload_for(repository)
        {
          id: repository.id,
          slug: repository.slug,
          owner: repository.owner,
          name: repository.name,
          default_branch: repository.default_branch,
          epic_dependency_policy: repository.epic_dependency_policy,
          created_at: repository.created_at.iso8601
        }
      end
    end
  end
end
