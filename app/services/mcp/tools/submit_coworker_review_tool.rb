require "mcp"
module Mcp::Tools
  class SubmitCoworkerReviewTool < MCP::Tool
    VERDICTS = %w[needs_work approved].freeze
    tool_name "submit_coworker_review"
    description "Stores findings from the accountable coworker reviewer."
    input_schema(properties: { critique: { type: "string" }, verdict: { type: "string", enum: VERDICTS } }, required: %w[critique verdict])
    class << self
      def call(critique:, verdict:, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_coworker_review)
        critique = Mcp::Tools.utf8(critique).strip
        verdict = Mcp::Tools.utf8(verdict).strip
        return Mcp::Tools.invalid("critique is required") if critique.empty?
        return Mcp::Tools.invalid("invalid verdict") unless VERDICTS.include?(verdict)
        ReviewEvidence::VerdictSubmission.call!(run: run, artifact_key: "coworker_review_iterations", review_kind: "coworker", verdict: verdict, critique: critique)
        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue StandardError => e
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
