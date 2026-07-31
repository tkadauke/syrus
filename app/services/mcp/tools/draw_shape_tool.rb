require "mcp"

module Mcp::Tools
  class DrawShapeTool < MCP::Tool
    tool_name "draw_shape"

    description "Append a rectangle, ellipse, diamond, or sticky shape to the whiteboard scene. The sticky type renders as a yellow rectangle."

    input_schema(
      properties: {
        type: { type: "string", description: "One of rectangle, ellipse, diamond, or sticky. sticky renders as a yellow rectangle with amber border." },
        x: { type: "number" },
        y: { type: "number" },
        width: { type: "number" },
        height: { type: "number" },
        label: { type: "string" },
        color: { type: "string" }
      },
      required: %w[type x y width height]
    )

    class << self
      def call(type:, x:, y:, width:, height:, server_context:, label: nil, color: nil)
        type = type.to_s
        return Mcp::Tools.invalid("type must be rectangle, ellipse, diamond, or sticky") unless Canvas::SHAPE_TYPES.include?(type)

        args = {
          "type" => type,
          "x" => Canvas.number(x, "x"),
          "y" => Canvas.number(y, "y"),
          "width" => Canvas.positive_number(width, "width"),
          "height" => Canvas.positive_number(height, "height"),
          "label" => label,
          "color" => color
        }.compact

        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |elements|
          Canvas.ensure_can_append_element!(elements)
          element = Canvas.shape_element(**args.symbolize_keys.except(:label))
          elements << element

          label_text = args["label"].to_s.strip
          if label_text.present?
            Canvas.ensure_can_append_element!(elements)
            label = Canvas.bound_label_element(container: element, text: label_text)
            element["boundElements"] = (element["boundElements"] || []) + [ { "id" => label.fetch("id"), "type" => "text" } ]
            elements << label
          end

          { id: element.fetch("id") }
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
