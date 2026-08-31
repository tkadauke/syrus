require "mcp"

module Mcp::Tools
  class ReadJobTestResultsTool < MCP::Tool
    extend TestInsightToolSupport

    tool_name "read_job_test_results"

    description <<~DESC
      Read compact ingested test results for the latest Workflow on a Job that
      has Test Insights data. Returns grader summaries plus bounded failed/error
      cases by default; opt into slow cases or full suite grouping when needed.
    DESC

    input_schema(
      properties: {
        job_id: {
          type: "string",
          description: "Syrus Job id or slug, e.g. 123 or JOB-123."
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
      required: %w[job_id]
    )

    class << self
      def call(server_context:, job_id:, grader_name: nil, include_slow_cases: false, include_suites: false, case_limit: nil)
        Mcp::Tools.with_database_connection do
          context = current_context(server_context)
          job = job_for(context, job_id: job_id)
          payload = TestInsights::RunResults.for_job(
            job: job,
            grader_name: grader_name,
            include_slow_cases: truthy?(include_slow_cases, default: false),
            include_suites: truthy?(include_suites, default: false),
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
