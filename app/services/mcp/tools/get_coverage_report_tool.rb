require "mcp"

module Mcp::Tools
  class GetCoverageReportTool < MCP::Tool
    tool_name "get_coverage_report"

    description "Get the test coverage report for the current job's most recent workflow run. Returns summary, per-file breakdown, and PR diff annotations. Use this to identify under-tested files before writing tests."

    input_schema(
      properties: {}
    )

    class << self
      def call(server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        artifact = find_latest_coverage_artifact(run)

        payload = if artifact.nil?
          { "coverage_unavailable" => true }
        else
          {
            "summary"          => artifact["summary"],
            "files"            => artifact["files"],
            "diff_annotations" => artifact["diff_annotations"],
            "pr_delta"         => artifact["pr_delta"],
            "threshold_miss"   => artifact["threshold_miss"],
            "sources_status"   => artifact["sources_status"]
          }
        end

        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::GetCoverageReportTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def find_latest_coverage_artifact(run)
        run.job.workflows.order(created_at: :desc).each do |w|
          artifact = Workflow::CoverageArtifact.read(w)
          return artifact if artifact.present?
        end
        nil
      end
    end
  end
end
