require "mcp"

module Mcp::Tools
  class CompareTestRuntimeTool < MCP::Tool
    extend TestInsightToolSupport

    tool_name "compare_test_runtime"

    description <<~DESC
      Compare bounded test runtime data for selected Test Insight identities
      across two Runs, two Jobs, or explicit before/after time windows. Returns
      sample count, avg, p50, p95, latest duration, deltas, and run worker
      health correlation when a source is a Run.
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
        test_identity_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Specific durable TestIdentity ids to compare. Capped at 25."
        },
        query: {
          type: "string",
          description: "Optional text search over test name, suite, and file path when test_identity_ids are omitted."
        },
        grader_name: {
          type: "string",
          description: "Optional grader name to compare only executions from one grader."
        },
        limit: {
          type: "integer",
          description: "Maximum identities to compare, capped at 25. Defaults to 10."
        },
        baseline_run_id: {
          type: "string",
          description: "Baseline Syrus Run id or slug, e.g. 456 or RUN-456."
        },
        comparison_run_id: {
          type: "string",
          description: "Comparison Syrus Run id or slug, e.g. 789 or RUN-789."
        },
        baseline_job_id: {
          type: "string",
          description: "Baseline Syrus Job id or slug. Uses that Job's latest Workflow with Test Insights data."
        },
        comparison_job_id: {
          type: "string",
          description: "Comparison Syrus Job id or slug. Uses that Job's latest Workflow with Test Insights data."
        },
        baseline_window: {
          type: "object",
          description: "Baseline time window with starts_at/from/start and ends_at/to/end ISO-8601 values."
        },
        comparison_window: {
          type: "object",
          description: "Comparison time window with starts_at/from/start and ends_at/to/end ISO-8601 values."
        }
      }
    )

    class << self
      def call(server_context:, repository: nil, repository_id: nil, test_identity_ids: nil, query: nil, grader_name: nil, limit: nil, baseline_run_id: nil, comparison_run_id: nil, baseline_job_id: nil, comparison_job_id: nil, baseline_window: nil, comparison_window: nil)
        Mcp::Tools.with_database_connection do
          context = current_context(server_context)
          target_repository = repository_for(context, repository: repository, repository_id: repository_id)
          payload = TestInsights::RuntimeComparison.call(
            user: context.user,
            repository: target_repository,
            test_identity_ids: test_identity_ids,
            query: query,
            grader_name: grader_name,
            limit: limit,
            baseline_run_id: baseline_run_id,
            comparison_run_id: comparison_run_id,
            baseline_job_id: baseline_job_id,
            comparison_job_id: comparison_job_id,
            baseline_window: baseline_window,
            comparison_window: comparison_window
          )

          Mcp::Tools.success(payload)
        end
      rescue ActiveRecord::RecordNotFound
        Mcp::Tools.not_authorized
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::CompareTestRuntimeTool] #{e.class}: #{e.message}")
        Mcp::Tools.invalid("#{e.class}: #{e.message}")
      end
    end
  end
end
