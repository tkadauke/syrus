require "mcp"

module Whiteboard
  class DrawArrowTool < MCP::Tool
    tool_name "draw_arrow"

    description <<~TEXT.squish
      Append an arrow bound to two existing elements so it follows them when they move or resize.
      Rectangle, sticky, ellipse, and diamond endpoints are placed on their visible edges. Rotated or
      unsupported elements use their centers as a safe fallback. An optional label renders as movable text
      bound to the arrow; no separate draw_text call or manual endpoint calculation is needed.
    TEXT

    input_schema(
      properties: {
        from_id: { type: "string" },
        to_id: { type: "string" },
        label: {
          type: "string",
          description: "Optional visible text bound to the arrow and initially centered on it."
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
          elements << arrow
          Canvas.bind_arrow_to_shapes!(elements, arrow)

          label_text = label.to_s.strip
          label_element = nil
          if label_text.present?
            Canvas.ensure_can_append_element!(elements)
            label_element = Canvas.bound_label_element(container: arrow, text: label_text)
            arrow["boundElements"] = Array(arrow["boundElements"]) + [ { "id" => label_element.fetch("id"), "type" => "text" } ]
            elements << label_element
          end

          { id: arrow.fetch("id"), label_id: label_element&.fetch("id") }.compact
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
