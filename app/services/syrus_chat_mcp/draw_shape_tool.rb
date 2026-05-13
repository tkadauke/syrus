require "mcp"

module SyrusChatMcp
  class DrawShapeTool < MCP::Tool
    tool_name "draw_shape"

    description "Append a rectangle, ellipse, diamond, or sticky shape to the whiteboard scene."

    input_schema(
      properties: {
        type: { type: "string", description: "One of rectangle, ellipse, diamond, or sticky." },
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
        return SyrusChatMcp.invalid("type must be rectangle, ellipse, diamond, or sticky") unless Canvas::SHAPE_TYPES.include?(type)

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
          element = Canvas.shape_element(**args.symbolize_keys)
          elements << element
          { id: element.fetch("id") }
        end

        SyrusChatMcp.success(result)
      rescue Canvas::ElementLimitExceeded => e
        SyrusChatMcp.tool_error(e.message)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.message)
      end
    end
  end
end
