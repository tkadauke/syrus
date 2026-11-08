require "mcp"
module Mcp::Tools
  class SubmitCoworkerReviewTool < MCP::Tool
    VERDICTS = %w[needs_work approved].freeze
    tool_name "submit_coworker_review"
    description "Stores findings from the accountable coworker reviewer."
    input_schema(properties: { critique: { type: "string" }, verdict: { type: "string", enum: VERDICTS },
                               key_learning: { type: "string", description: "Durable, concise learning from this review." } },
                 required: %w[critique verdict key_learning])
    class << self
      def call(critique:, verdict:, server_context:, key_learning: nil)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_coworker_review)
        critique = Mcp::Tools.utf8(critique).strip
        verdict = Mcp::Tools.utf8(verdict).strip
        key_learning = Mcp::Tools.utf8(key_learning).strip
        return Mcp::Tools.invalid("critique is required") if critique.empty?
        return Mcp::Tools.invalid("invalid verdict") unless VERDICTS.include?(verdict)
        reviewer = run.review_evidence&.reviewer
        return Mcp::Tools.invalid("key_learning is required") if reviewer&.respond_to?(:finalize_review_memory!) && key_learning.empty?
        ReviewEvidence::VerdictSubmission.call!(run: run, artifact_key: "coworker_review_iterations", review_kind: "coworker",
          verdict: verdict, critique: critique, key_learning: key_learning)
        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue Steps::AdversarialReview::MemoryPersistenceFailed
        raise
      rescue StandardError => e
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
