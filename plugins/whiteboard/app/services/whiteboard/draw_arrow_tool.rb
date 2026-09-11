require "mcp"

module Whiteboard
  class DrawArrowTool < MCP::Tool
    tool_name "draw_arrow"

    description <<~TEXT.squish
      Append an arrow bound to two existing elements so it follows them when they move.
      Bound arrows connect at element centers, not edges, so they will visually cut through shape interiors
      and their labels when connecting shapes that have their own text. For diagrams connecting multiple
      labeled shapes, prefer draw_line with type: "arrow" and manually-computed edge-anchored x/y/points.
      The label parameter does not currently render as visible text; use a separate draw_text call positioned
      near the arrow's midpoint instead.
    TEXT

    input_schema(
      properties: {
        from_id: { type: "string" },
        to_id: { type: "string" },
        label: {
          type: "string",
          description: "Currently stored on the arrow JSON but not rendered as visible text. " \
            "Use a separate draw_text call near the arrow midpoint instead."
        }
      },
      required: %w[from_id to_id]
    )

    class << self
      def call(from_id:, to_id:, server_context:, label: nil)
        from_id = from_id.to_s
        to_id = to_id.to_s
        return Mcp::Tools.invalid("from_id is required") if from_id.empty?
        return Mcp::Tools.invalid("to_id is required") if to_id.empty?

        args = { "from_id" => from_id, "to_id" => to_id, "label" => label }.compact

        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |elements|
          Canvas.ensure_can_append_element!(elements)
          from_element = Canvas.find_element(elements, from_id)
          to_element = Canvas.find_element(elements, to_id)
          arrow = Canvas.arrow_element(from_element, to_element)
          arrow["label"] = label.to_s if label.present?
          elements << arrow
          Canvas.bind_arrow_to_shapes!(elements, arrow)
          { id: arrow.fetch("id") }
        end

        Mcp::Tools.success(result)
      rescue Canvas::ElementLimitExceeded => e
        Mcp::Tools.tool_error(e.message)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
