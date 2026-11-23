require "mcp"
module Coworkers
  class SubmitReviewTool < MCP::Tool
    VERDICTS = %w[needs_work approved].freeze
    tool_name "submit_coworker_review"
    description "Stores findings from the accountable coworker reviewer."
    input_schema(properties: { critique: { type: "string" }, verdict: { type: "string", enum: VERDICTS },
                               key_learning: { type: "string", description: "Durable, concise learning from this review." } },
                 required: %w[critique verdict key_learning])
    class << self
      def call(critique:, verdict:, server_context:, key_learning: nil)
        run = Syrus::Host::McpTools.run_from_context(server_context)
        context = Syrus::Host::ToolContext.from_run(run)
        return Syrus::Host::McpTools.not_authorized unless Coworkers::ReviewToolSet::SUBMIT_ROLES.include?(context.role)
        critique = Syrus::Host::McpTools.utf8(critique).strip
        verdict = Syrus::Host::McpTools.utf8(verdict).strip
        key_learning = Syrus::Host::McpTools.utf8(key_learning).strip
        return Syrus::Host::McpTools.invalid("critique is required") if critique.empty?
        return Syrus::Host::McpTools.invalid("invalid verdict") unless VERDICTS.include?(verdict)
        reviewer = run.review_evidence&.then { |evidence| Coworkers::ReviewEvidenceTarget.resolve(evidence, run:) }
        return Syrus::Host::McpTools.invalid("key_learning is required") if reviewer&.respond_to?(:finalize_review_memory!) && key_learning.empty?
        Syrus::Host::ReviewEvidenceVerdictSubmission.call!(run: run, artifact_key: "coworker_review_iterations", review_kind: "coworker",
          verdict: verdict, critique: critique, key_learning: key_learning)
        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue Syrus::Host::StepsAdversarialReviewMemoryPersistenceFailed
        raise
      rescue StandardError => e
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
