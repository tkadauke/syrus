require "mcp"

module Mcp::Tools
  class ReadRunTestResultsTool < MCP::Tool
    extend TestInsightToolSupport

    tool_name "read_run_test_results"

    description <<~DESC
      Read compact ingested Test Insights results for a specific Syrus Run.
      Use grader_name to inspect one grader. Returns summaries plus bounded
      failed/error cases by default.
    DESC

    input_schema(
      properties: {
        run_id: {
          type: "string",
          description: "Syrus Run id or slug, e.g. 456 or RUN-456."
        },
        grader_name: {
          type: "string",
          description: "Optional grader name to restrict results to one grader."
        },
        include_slow_cases: {
          type: "boolean",
          description: "Include the slowest cases per test run, bounded by case_limit. Defaults to false."
        },
        include_suites: {
          type: "boolean",
          description: "Include full suite grouping and cases. Defaults to false to keep output compact."
        },
        case_limit: {
          type: "integer",
          description: "Maximum failed/error or slow cases per test run, capped at 100. Defaults to 20."
        }
      },
      required: %w[run_id]
    )

    class << self
      def call(server_context:, run_id:, grader_name: nil, include_slow_cases: false, include_suites: false, case_limit: nil)
        Mcp::Tools.with_database_connection do
          context = current_context(server_context)
          run = run_for(context, run_id: run_id)
          payload = TestInsights::RunResults.for_run(
            run: run,
            grader_name: grader_name,
            include_slow_cases: truthy?(include_slow_cases),
            include_suites: truthy?(include_suites),
            case_limit: case_limit
          )

          Mcp::Tools.success(payload)
        end
      rescue ActiveRecord::RecordNotFound
        Mcp::Tools.not_authorized
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::ReadRunTestResultsTool] #{e.class}: #{e.message}")
        Mcp::Tools.invalid("#{e.class}: #{e.message}")
      end
    end
  end
end
