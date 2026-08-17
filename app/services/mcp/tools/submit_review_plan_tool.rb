require "mcp"

module Mcp::Tools
  # Stores the agent-authored self-review plan on the Workflow so the
  # review_plan step can post it as a structured PR comment.
  class SubmitReviewPlanTool < MCP::Tool
    tool_name "submit_review_plan"

    description <<~DESC
      Stores a self-review pass over the agent's own diff on the current
      Workflow. The Syrus harness invokes this tool from the review_plan
      step, after the PR has been opened. items should point at concrete
      file/line locations worth a human reviewer's closer attention and
      explain why — not restate what the diff does. Skip routine or
      obvious changes; submit an empty items list if nothing stands out.
    DESC

    input_schema(
      properties: {
        items: {
          type: "array",
          items: {
            type: "object",
            properties: {
              file: { type: "string", description: "Path of the file to point the reviewer at." },
              line: { type: "integer", description: "Optional line number, when the note is anchored to a specific line." },
              note: { type: "string", description: "Why a human reviewer should look closely here." }
            },
            required: %w[file note]
          },
          description: "2-6 specific, high-signal review points. Empty when nothing stands out."
        },
        summary: {
          type: "string",
          description: "Optional short overall note."
        }
      },
      required: %w[items]
    )

    class << self
      def call(items:, summary: nil, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_review_plan)

        normalized_items = normalize_items(items)
        return Mcp::Tools.invalid("items must be an array") if normalized_items.nil?

        run.workflow.set_artifact!("review_plan", {
          items: normalized_items,
          summary: Mcp::Tools.utf8(summary).strip.presence
        })
        Mcp::Tools.write_log(run, "[mcp] submit_review_plan received: #{normalized_items.size} item(s)")

        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::SubmitReviewPlanTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def normalize_items(items)
        return nil unless items.is_a?(Array)

        items.filter_map do |item|
          next unless item.is_a?(Hash)

          file = Mcp::Tools.utf8(item["file"] || item[:file]).strip
          note = Mcp::Tools.utf8(item["note"] || item[:note]).strip
          next if file.empty? || note.empty?

          line = (item["line"] || item[:line]).presence&.to_i

          { "file" => file, "line" => line, "note" => note }
        end
      end
    end
  end
end
