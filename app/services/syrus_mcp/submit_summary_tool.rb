require "mcp"

module SyrusMcp
  # The single MCP tool exposed by the per-run sidecar. The agent calls
  # this near the end of every run with the PR title, PR body, and an
  # operator-facing summary. Values land on the Run record; RunJob reads
  # them when opening (or skipping) the GitHub PR.
  class SubmitSummaryTool < MCP::Tool
    tool_name "submit_summary"

    description <<~DESC
      Hand a PR title, PR body, and operator-facing summary back to Syrus.
      Call this near the end of every run. On the initial run Syrus uses
      pr_title and pr_body to open the GitHub PR. On follow-up runs (pr_comment,
      replay, etc.) the PR already exists — pr_title becomes the git commit
      message for this revision's commit (describe what changed in this pass,
      not the whole PR), and pr_body is stored per-run but not pushed to GitHub.
      summary is shown on the Syrus job page either way.
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
        run = server_context[:run].reload

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

        MCP::Tool::Response.new([{ type: "text", text: "Saved." }])
      end

      private

      def invalid(reason)
        MCP::Tool::Response.new([{ type: "text", text: "Error: #{reason}" }], error: true)
      end
    end
  end
end
