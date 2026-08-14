require "mcp"

module Mcp::Tools
  class SubmitVisualReviewTool < MCP::Tool
    VERDICTS = %w[needs_work approved skipped].freeze

    tool_name "submit_visual_review"

    description <<~DESC
      Stores visual review findings on the current Workflow.
      The visual_review step invokes an independent reviewer agent that
      drives a headless browser against its own preview; critique should
      capture concrete visual findings and verdict records whether the
      implementation needs more work, is approved, or was not visually
      testable (skipped).
    DESC

    input_schema(
      properties: {
        critique: {
          type: "string",
          description: "Concise Markdown critique with concrete visual findings, a short note that no blocking issues were found, or the reason visual review was skipped."
        },
        verdict: {
          type: "string",
          enum: VERDICTS,
          description: "needs_work when implementation changes are needed; approved when the change looks correct; skipped when the change isn't visually testable."
        }
      },
      required: %w[critique verdict]
    )

    class << self
      def call(critique:, verdict:, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_visual_review)

        normalized_critique = Mcp::Tools.utf8(critique).strip
        normalized_verdict = Mcp::Tools.utf8(verdict).strip

        return Mcp::Tools.invalid("critique is required") if normalized_critique.empty?
        return Mcp::Tools.invalid("verdict must be one of: #{VERDICTS.join(', ')}") unless VERDICTS.include?(normalized_verdict)

        workflow = run.workflow
        iterations = Array(workflow.artifact("visual_review_iterations"))
        iterations << {
          "iteration" => run.step.iteration,
          "critique" => normalized_critique,
          "verdict" => normalized_verdict
        }
        workflow.set_artifact!("visual_review_iterations", iterations)
        Mcp::Tools.write_log(run, "[mcp] submit_visual_review received: #{normalized_verdict}")

        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::SubmitVisualReviewTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
