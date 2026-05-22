require "mcp"

module SyrusMcp
  # The single MCP tool exposed by the per-run sidecar. Values land on
  # the Run record; RunJob reads them when opening (or skipping) the
  # GitHub PR.
  class SubmitSummaryTool < MCP::Tool
    tool_name "submit_summary"

    description <<~DESC
      Stores a PR title, PR body, and operator-facing summary on the current Run.
      The Syrus harness invokes this tool from the summarize / summarize_amend
      step; the implement and respond steps do not require it. On the initial
      workflow, pr_title and pr_body are used to open the GitHub PR. On follow-up
      workflows (pr_comment, retry, etc.), the PR already exists; pr_title becomes
      the git commit message for this revision's commit, and pr_body is stored
      per-run but not pushed to GitHub. summary is shown on the Syrus job page
      either way.
    DESC

    input_schema(
      properties: {
        pr_title: {
          type: "string",
          description: "50–72 chars, imperative mood (\"Add greeting helper\", not \"Adds greeting helper\" or \"This PR adds…\")."
        },
        pr_body: {
          type: "string",
          description: "Markdown, 1–3 short paragraphs. Lead with why; mention what changed. No headings, no \"This PR…\" preamble."
        },
        summary: {
          type: "string",
          description: "1–2 sentences for the Syrus job page describing what this run did."
        }
      },
      required: %w[pr_title pr_body summary]
    )

    class << self
      MAX_TITLE_LENGTH = 120

      def call(pr_title:, pr_body:, summary:, server_context:)
        run = SyrusMcp.run_from_context(server_context)

        title   = pr_title.to_s.strip
        body    = pr_body.to_s.strip
        summary = summary.to_s.strip

        return invalid("pr_title is required")                          if title.empty?
        return invalid("pr_title too long (#{title.length} chars)")     if title.length > MAX_TITLE_LENGTH
        return invalid("pr_body is required")                           if body.empty?
        return invalid("summary is required")                           if summary.empty?

        run.update!(
          agent_pr_title: title,
          agent_pr_body:  body,
          agent_summary:  summary
        )
        SyrusMcp.write_log(run, "[mcp] submit_summary received: #{title.inspect}")

        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::SubmitSummaryTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def invalid(reason)
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{reason}" } ], error: true)
      end
    end
  end
end
