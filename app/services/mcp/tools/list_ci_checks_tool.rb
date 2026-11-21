require "mcp"

module Mcp::Tools
  class ListCiChecksTool < MCP::Tool
    tool_name "list_ci_checks"

    description <<~DESC
      List the CI checks on this Job's pull request head (or another pull
      request in the same repository): name, status, conclusion, summary and
      whether a log can be read with read_ci_log. Read-only; uses Syrus's own
      GitHub access, so no gh CLI or token is needed.
    DESC

    input_schema(
      properties: {
        pr_number: { type: "integer", description: "Pull request number. Defaults to this Job's pull request." }
      }
    )

    class << self
      def call(server_context:, pr_number: nil)
        target = CiCheckLookup.target(server_context, pr_number:)
        return target if target.is_a?(MCP::Tool::Response)

        checks = CiCheckLookup.checks(target).map do |check|
          {
            name: check[:name],
            status: check[:status],
            conclusion: check[:conclusion].presence,
            summary: check[:summary].present? ? ToolPayloadRedactor.redact_text(check[:summary].to_s) : nil,
            html_url: check[:html_url],
            log_available: check[:actions_job_id].present? || check[:output_text].present?
          }.compact
        end

        Mcp::Tools.success(pr_number: target.pr_number, head_sha: target.sha, checks: checks)
      rescue Octokit::Error => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
