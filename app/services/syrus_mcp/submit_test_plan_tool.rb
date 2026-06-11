require "mcp"

module SyrusMcp
  # Stores the agent-authored manual test plan on the Workflow so
  # downstream steps and admin APIs can read it without scraping logs.
  class SubmitTestPlanTool < MCP::Tool
    tool_name "submit_test_plan"

    description <<~DESC
      Stores a concise, actionable test plan on the current Workflow.
      The Syrus harness invokes this tool from the test_plan step after
      implementation and summary are complete. steps should name exact
      user flows, URLs, commands, and edge cases worth exercising; notes
      may include short context that does not fit naturally as a step.
    DESC

    input_schema(
      properties: {
        steps: {
          type: "array",
          items: { type: "string" },
          description: "Concise, actionable test steps: user flows, URLs, commands, and known edge cases."
        },
        notes: {
          type: "string",
          description: "Optional short context for reviewers."
        }
      },
      required: %w[steps]
    )

    class << self
      def call(steps:, notes: nil, server_context:)
        run = SyrusMcp.run_from_context(server_context)

        normalized_steps = Array(steps).map { |step| utf8(step).strip }.reject(&:empty?)
        normalized_notes = utf8(notes).strip.presence

        return invalid("steps must include at least one item") if normalized_steps.empty?

        run.workflow.set_artifact!("test_plan", {
          steps: normalized_steps,
          notes: normalized_notes
        })
        SyrusMcp.write_log(run, "[mcp] submit_test_plan received: #{normalized_steps.size} step(s)")

        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::SubmitTestPlanTool] #{e.class}: #{e.message}")
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
