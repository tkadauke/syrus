require "mcp"

module Mcp::Tools
  class DrawFreedrawTool < MCP::Tool
    tool_name "draw_freedraw"

    description "Append a freehand Excalidraw path to the whiteboard scene."

    input_schema(
      properties: {
        x: { type: "number" },
        y: { type: "number" },
        points: { type: "array", description: "Local points as [x,y] arrays or {x,y} objects." },
        pressures: { type: "array", description: "Optional pressure values, one per point." },
        simulate_pressure: { type: "boolean" },
        color: { type: "string" },
        stroke_width: { type: "integer" }
      },
      required: %w[x y points]
    )

    class << self
      def call(x:, y:, points:, server_context:, pressures: nil, simulate_pressure: true, color: nil, stroke_width: nil)
        x = Canvas.number(x, "x")
        y = Canvas.number(y, "y")
        args = {
          "x" => x,
          "y" => y,
          "points" => points,
          "pressures" => pressures,
          "simulate_pressure" => simulate_pressure,
          "color" => color,
          "stroke_width" => stroke_width
        }.compact

        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |elements|
          Canvas.ensure_can_append_element!(elements)
          element = Canvas.freedraw_element(
            x: x,
            y: y,
            points: points,
            pressures: pressures,
            simulate_pressure: simulate_pressure,
            stroke_color: color,
            stroke_width: stroke_width
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
