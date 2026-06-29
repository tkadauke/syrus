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

        normalized_critique = utf8(critique).strip
        normalized_verdict = utf8(verdict).strip

        return invalid("critique is required") if normalized_critique.empty?
        return invalid("verdict must be one of: #{VERDICTS.join(', ')}") unless VERDICTS.include?(normalized_verdict)

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

      private

      def invalid(reason)
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{reason}" } ], error: true)
      end

      def utf8(text)
        string = text.to_s
        if string.encoding == Encoding::ASCII_8BIT
          string.dup.force_encoding(Encoding::UTF_8).scrub("")
        else
          string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
        end
      end
    end
  end
end
