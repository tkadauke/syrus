require "mcp"

module Mcp::Tools
  # Stores the agent-authored investigation report on the current Workflow.
  # The Syrus harness invokes this tool from the submit_report step of
  # `investigation` Workflows -- the narrative-producing step the chain
  # exists to reach instead of dead-ending on a blank diff. There is no PR
  # for this narrative to ride along with, so it lands directly on
  # Workflow#artifacts under "investigation_report".
  class SubmitReportTool < MCP::Tool
    tool_name "submit_report"

    MAX_TITLE_LENGTH = 120
    MAX_NARRATIVE_LENGTH = 20_000
    MAX_FINDINGS = 10
    MAX_FINDING_LENGTH = 240

    description <<~DESC
      Stores a narrative investigation report on the current Workflow. The
      Syrus harness invokes this tool from the submit_report step of an
      investigation Job -- there is no PR, so this report is the Job's
      deliverable. title is a short label; narrative is the full
      markdown write-up (your answer plus the evidence for it); findings
      is an optional list of concise, standalone call-outs.
    DESC

    input_schema(
      properties: {
        title: {
          type: "string",
          description: "Short title for the report, under #{MAX_TITLE_LENGTH} characters."
        },
        narrative: {
          type: "string",
          description: "Full report body in markdown: your answer, the evidence for it, and any caveats."
        },
        findings: {
          type: "array",
          items: { type: "string" },
          maxItems: MAX_FINDINGS,
          description: "Optional list of at most #{MAX_FINDINGS} short, standalone findings."
        }
      },
      required: %w[title narrative]
    )

    class << self
      def call(title:, narrative:, findings: nil, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_report)

        normalized_title = Mcp::Tools.utf8(title).strip.truncate(MAX_TITLE_LENGTH)
        normalized_narrative = Mcp::Tools.utf8(narrative).strip.truncate(MAX_NARRATIVE_LENGTH)
        normalized_findings = normalize_findings(findings)

        return Mcp::Tools.invalid("title is required")     if normalized_title.empty?
        return Mcp::Tools.invalid("narrative is required")  if normalized_narrative.empty?

        run.workflow.set_artifact!("investigation_report", {
          title: normalized_title,
          narrative: normalized_narrative,
          findings: normalized_findings
        })
        Mcp::Tools.write_log(run, "[mcp] submit_report received: #{normalized_title.inspect}")

        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::SubmitReportTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def normalize_findings(findings)
        Array(findings).map { |finding| Mcp::Tools.utf8(finding).strip.truncate(MAX_FINDING_LENGTH) }.reject(&:empty?).first(MAX_FINDINGS)
      end
    end
  end
end
