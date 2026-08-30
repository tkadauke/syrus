require "mcp"

module Mcp::Tools
  class ListRepositoryTestInsightsTool < MCP::Tool
    extend TestInsightToolSupport

    tool_name "list_repository_test_insights"

    description <<~DESC
      List durable Test Insights for a repository the caller can access. Use
      filter/category values like recently_seen, failing, flaky, or slow. For
      slow-test investigations, pass sort: "last_duration" and direction:
      "desc" to rank by each test identity's latest recorded duration.
    DESC

    input_schema(
      properties: {
        repository: {
          type: "string",
          description: "Repository slug as owner/name. Optional for workflow agents, which default to the current Run's repository."
        },
        repository_id: {
          type: "integer",
          description: "Repository id. Takes precedence over repository when present."
        },
        filter: {
          type: "string",
          description: "Test category: recently_seen, failing, flaky, or slow. Alias: category."
        },
        category: {
          type: "string",
          description: "Alias for filter."
        },
        sort: {
          type: "string",
          description: "Sort key: last_seen, last_failed, last_duration, or failure_rate."
        },
        direction: {
          type: "string",
          description: "Sort direction: desc or asc."
        },
        query: {
          type: "string",
          description: "Optional text search over test name, suite, and file path."
        },
        grader_name: {
          type: "string",
          description: "Optional grader name to restrict results to tests observed by that grader."
        },
        limit: {
          type: "integer",
          description: "Maximum tests to return, capped at 100. Defaults to 25."
        },
        lookback: {
          type: "integer",
          description: "Recent execution window used for failure/pass counts and average duration, capped at 100."
        },
        filters: {
          type: "object",
          description: "Optional summary filters: min/max last duration, last_seen/last_failed time bounds, min/max failure rate."
        }
      }
    )

    class << self
      def call(server_context:, repository: nil, repository_id: nil, filter: nil, category: nil, sort: nil, direction: nil, query: nil, grader_name: nil, limit: nil, lookback: nil, filters: {})
        Mcp::Tools.with_database_connection do
          context = current_context(server_context)
          target_repository = repository_for(context, repository: repository, repository_id: repository_id)
          result = TestInsights::Query.call(
            user: context.user,
            repository: target_repository,
            category: normalize_filter(filter) || normalize_filter(category),
            sort: sort,
            direction: direction,
            query: query,
            grader_name: grader_name,
            limit: limit,
            filters: normalize_filters(filters, lookback)
          )

          Mcp::Tools.success(
            repository: repository_payload(result.repository),
            filter: result.category,
            sort: result.sort,
            direction: result.direction,
            query: result.query,
            grader_name: grader_name.to_s.presence,
            lookback: normalize_filters(filters, lookback)[:lookback] || TestInsights::Query::DEFAULT_LOOKBACK,
            limit: result.limit,
            tests: result.tests
          )
        end
      rescue ActiveRecord::RecordNotFound
        Mcp::Tools.not_authorized
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::ListRepositoryTestInsightsTool] #{e.class}: #{e.message}")
        Mcp::Tools.invalid("#{e.class}: #{e.message}")
      end

      private

      def repository_payload(repository)
        {
          id: repository.id,
          slug: repository.slug,
          github_url: "https://github.com/#{repository.slug}"
        }
      end
    end
  end
end
