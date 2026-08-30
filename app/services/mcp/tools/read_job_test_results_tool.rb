require "mcp"

module Mcp::Tools
  class ReadJobTestResultsTool < MCP::Tool
    extend TestInsightToolSupport

    tool_name "read_job_test_results"

    description <<~DESC
      Read compact ingested test results for the latest workflow on a Job that
      has test data. Returns grader summaries and bounded failed/error cases by
      default, with optional slow cases or suite grouping.
    DESC

    input_schema(
      properties: {
        job_id: {
          type: "integer",
          description: "Job id to inspect."
        },
        grader_name: {
          type: "string",
          description: "Optional grader name to restrict returned test runs."
        },
        include_slow_cases: {
          type: "boolean",
          description: "Include each grader's slowest cases. Defaults to false."
        },
        include_suites: {
          type: "boolean",
          description: "Include bounded suite-grouped cases. Defaults to false."
        },
        case_limit: {
          type: "integer",
          description: "Failed/error cases per test run, capped at 100. Defaults to 20."
        }
      },
      required: %w[job_id]
    )

    class << self
      def call(server_context:, job_id:, grader_name: nil, include_slow_cases: false, include_suites: false, case_limit: nil)
        Mcp::Tools.with_database_connection do
          context = current_context(server_context)
          payload = TestInsights::RunResults.for_job(
            user: context.user,
            job_id: job_id,
            repository_id: context.run? ? context.repository&.id : nil,
            grader_name: normalize_filter(grader_name),
            include_slow_cases: truthy?(include_slow_cases),
            include_suites: truthy?(include_suites),
            case_limit: case_limit
          )

          Mcp::Tools.success(payload)
        end
      rescue ActiveRecord::RecordNotFound
        Mcp::Tools.not_authorized
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::ReadJobTestResultsTool] #{e.class}: #{e.message}")
        Mcp::Tools.invalid("#{e.class}: #{e.message}")
      end
    end
  end
end
