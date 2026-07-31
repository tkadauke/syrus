require "mcp"

module Mcp::Tools
  class DrawFrameTool < MCP::Tool
    tool_name "draw_frame"

    description "Append an Excalidraw frame or magicframe to the whiteboard scene."

    input_schema(
      properties: {
        type: { type: "string", enum: %w[frame magicframe], description: "Defaults to frame." },
        x: { type: "number" },
        y: { type: "number" },
        width: { type: "number" },
        height: { type: "number" },
        name: { type: "string" }
      },
      required: %w[x y width height]
    )

    class << self
      def call(x:, y:, width:, height:, server_context:, type: "frame", name: nil)
        args = {
          "type" => type,
          "x" => x,
          "y" => y,
          "width" => width,
          "height" => height,
          "name" => name
        }.compact

        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |elements|
          Canvas.ensure_can_append_element!(elements)
          element = Canvas.frame_element(
            type: type,
            x: Canvas.number(x, "x"),
            y: Canvas.number(y, "y"),
            width: Canvas.positive_number(width, "width"),
            height: Canvas.positive_number(height, "height"),
            name: name
          )
          elements << element
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
