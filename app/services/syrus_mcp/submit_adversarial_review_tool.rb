require "mcp"

module SyrusMcp
  class SubmitAdversarialReviewTool < MCP::Tool
    VERDICTS = %w[needs_work approved].freeze

    tool_name "submit_adversarial_review"

    description <<~DESC
      Stores adversarial review findings on the current Workflow.
      The adversarial_review step invokes an independent reviewer agent;
      critique should capture concrete findings and verdict records whether
      the implementation needs more work or is approved.
    DESC

    input_schema(
      properties: {
        critique: {
          type: "string",
          description: "Concise Markdown critique with concrete findings, or a short note that no blocking issues were found."
        },
        verdict: {
          type: "string",
          enum: VERDICTS,
          description: "needs_work when implementation changes are needed; approved otherwise."
        }
      },
      required: %w[critique verdict]
    )

    class << self
      def call(critique:, verdict:, server_context:)
        run = SyrusMcp.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return SyrusMcp.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_adversarial_review)

        normalized_critique = SyrusMcp.utf8(critique).strip
        normalized_verdict = SyrusMcp.utf8(verdict).strip

        return SyrusMcp.invalid("critique is required") if normalized_critique.empty?
        return SyrusMcp.invalid("verdict must be one of: #{VERDICTS.join(', ')}") unless VERDICTS.include?(normalized_verdict)

        workflow = run.workflow
        iterations = Array(workflow.artifact("adversarial_review_iterations"))
        iterations << {
          "iteration" => run.step.iteration,
          "critique" => normalized_critique,
          "verdict" => normalized_verdict
        }
        workflow.set_artifact!("adversarial_review_iterations", iterations)
        SyrusMcp.write_log(run, "[mcp] submit_adversarial_review received: #{normalized_verdict}")

        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::SubmitAdversarialReviewTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

    end
  end
end
