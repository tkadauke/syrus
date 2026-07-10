require "mcp"

module SyrusMcp
  # MCP tool for agents to self-report suspicion that the main branch
  # was already broken before their changes. Crowd-quorum logic in
  # MainConcernAggregator triggers the shared broken-main response once
  # enough agents report within the rolling window.
  class ReportMainConcernTool < MCP::Tool
    tool_name "report_main_concern"

    description <<~DESC
      Call this if CI or graders are failing in files you did not modify,
      suggesting the main branch was already broken before your changes.
      Provide the failing test/grader names and your reasoning.
    DESC

    input_schema(
      properties: {
        reason: {
          type: "string",
          description: "Your reasoning for why main is likely broken independent of your changes."
        },
        failing_tests: {
          type: "array",
          items: { type: "string" },
          description: "Names of the failing tests or graders that appear unrelated to your changes."
        }
      },
      required: %w[reason]
    )

    class << self
      def call(reason:, failing_tests: nil, server_context:)
        run = SyrusMcp.run_from_context(server_context)

        normalized_reason = SyrusMcp.utf8(reason).strip
        return SyrusMcp.invalid("reason is required") if normalized_reason.empty?

        normalized_tests = Array(failing_tests).map { |t| SyrusMcp.utf8(t).strip }.reject(&:empty?)

        repository = run.job.repository

        MainConcernReport.create!(
          repository: repository,
          job: run.job,
          workflow: run.workflow,
          run: run,
          reason: normalized_reason,
          failing_tests: normalized_tests.presence
        )

        SyrusMcp.write_log(run, "[mcp] report_main_concern: #{normalized_reason.truncate(120)}")

        MainConcernAggregator.check!(repository)

        MCP::Tool::Response.new([ { type: "text", text: "Reported. The system will investigate if multiple agents confirm." } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ReportMainConcernTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
