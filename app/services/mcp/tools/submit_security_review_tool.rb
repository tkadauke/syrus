require "mcp"

module Mcp::Tools
  class SubmitSecurityReviewTool < MCP::Tool
    VERDICTS = %w[needs_work approved].freeze

    tool_name "submit_security_review"
    description "Stores security review findings on the current Workflow."
    input_schema(
      properties: {
        critique: { type: "string", description: "Concise Markdown security critique." },
        verdict: { type: "string", enum: VERDICTS, description: "needs_work or approved." }
      },
      required: %w[critique verdict]
    )

    class << self
      def call(critique:, verdict:, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_security_review)

        normalized_critique = Mcp::Tools.utf8(critique).strip
        normalized_verdict = Mcp::Tools.utf8(verdict).strip
        return Mcp::Tools.invalid("critique is required") if normalized_critique.empty?
        return Mcp::Tools.invalid("verdict must be one of: #{VERDICTS.join(', ')}") unless VERDICTS.include?(normalized_verdict)

        ReviewEvidence::VerdictSubmission.call!(
          run: run, artifact_key: "security_review_iterations", review_kind: "security",
          verdict: normalized_verdict, critique: normalized_critique
        )
        Mcp::Tools.write_log(run, "[mcp] submit_security_review received: #{normalized_verdict}")
        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::SubmitSecurityReviewTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
