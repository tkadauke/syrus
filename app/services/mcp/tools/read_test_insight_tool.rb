require "mcp"

module Mcp::Tools
  class ReadTestInsightTool < MCP::Tool
    extend TestInsightToolSupport

    tool_name "read_test_insight"

    description <<~DESC
      Read one durable Test Insight identity, including recent execution
      history, duration points, related grader/run/job references, and bounded
      failure snippets. Use list_repository_test_insights first when you need
      to find a test_identity_id.
    DESC

    input_schema(
      properties: {
        test_identity_id: {
          type: "integer",
          description: "Durable TestIdentity id returned by list_repository_test_insights."
        },
        history_limit: {
          type: "integer",
          description: "Recent executions to return, capped at 100. Defaults to 25."
        },
        include_failures: {
          type: "boolean",
          description: "Whether to include bounded failure message/backtrace/output snippets. Defaults to true."
        }
      },
      required: %w[test_identity_id]
    )

    class << self
      def call(server_context:, test_identity_id:, history_limit: nil, include_failures: true)
        Mcp::Tools.with_database_connection do
          context = current_context(server_context)
          identity = TestIdentity.find(test_identity_id)
          repository_for(context, repository_id: identity.repository_id)
          payload = TestInsights::Detail.call(
            user: context.user,
            test_identity_id: test_identity_id,
            history_limit: history_limit,
            include_failures: truthy?(include_failures, default: true)
          )

          Mcp::Tools.success(payload)
        end
      rescue ActiveRecord::RecordNotFound
        Mcp::Tools.not_authorized
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::ReadTestInsightTool] #{e.class}: #{e.message}")
        Mcp::Tools.invalid("#{e.class}: #{e.message}")
      end
    end
  end
end
