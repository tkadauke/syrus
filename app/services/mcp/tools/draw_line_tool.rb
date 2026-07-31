require "mcp"

module Mcp::Tools
  class DrawLineTool < MCP::Tool
    tool_name "draw_line"

    description "Append a line or unbound arrow to the whiteboard scene. Supports polyline points and Excalidraw arrowhead styles."

    input_schema(
      properties: {
        type: { type: "string", enum: %w[line arrow], description: "Defaults to line. Use arrow for an unbound arrow." },
        x: { type: "number" },
        y: { type: "number" },
        width: { type: "number", description: "Used with height when points are omitted." },
        height: { type: "number", description: "Used with width when points are omitted." },
        points: { type: "array", description: "Optional local points as [x,y] arrays or {x,y} objects." },
        color: { type: "string" },
        stroke_width: { type: "integer" },
        start_arrowhead: { type: "string" },
        end_arrowhead: { type: "string" }
      },
      required: %w[x y]
    )

    class << self
      def call(x:, y:, server_context:, type: "line", width: nil, height: nil, points: nil, color: nil, stroke_width: nil, start_arrowhead: nil, end_arrowhead: nil)
        x = Canvas.number(x, "x")
        y = Canvas.number(y, "y")
        points ||= default_points(width, height)

        args = {
          "type" => type,
          "x" => x,
          "y" => y,
          "points" => points,
          "color" => color,
          "stroke_width" => stroke_width,
          "start_arrowhead" => start_arrowhead,
          "end_arrowhead" => end_arrowhead
        }.compact

        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |elements|
          Canvas.ensure_can_append_element!(elements)
          element = Canvas.line_element(
            type: type,
            x: x,
            y: y,
            points: points,
            stroke_color: color,
            stroke_width: stroke_width,
            start_arrowhead: start_arrowhead,
            end_arrowhead: end_arrowhead
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

      private

      def default_points(width, height)
        [
          [ 0, 0 ],
          [ Canvas.number(width || 100, "width"), Canvas.number(height || 0, "height") ]
        ]
      end
    end
  end
end
