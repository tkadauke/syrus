require "mcp"

module Mcp::Tools
  class DrawEmbedTool < MCP::Tool
    tool_name "draw_embed"

    description "Append an Excalidraw embeddable or iframe element with a link."

    input_schema(
      properties: {
        type: { type: "string", enum: %w[embeddable iframe], description: "Defaults to embeddable." },
        link: { type: "string" },
        x: { type: "number" },
        y: { type: "number" },
        width: { type: "number" },
        height: { type: "number" }
      },
      required: %w[link x y width height]
    )

    class << self
      def call(link:, x:, y:, width:, height:, server_context:, type: "embeddable")
        link = link.to_s
        return Mcp::Tools.invalid("link is required") if link.blank?

        args = {
          "type" => type,
          "link" => link,
          "x" => x,
          "y" => y,
          "width" => width,
          "height" => height
        }

        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |elements|
          Canvas.ensure_can_append_element!(elements)
          element = Canvas.embed_element(
            type: type,
            link: link,
            x: Canvas.number(x, "x"),
            y: Canvas.number(y, "y"),
            width: Canvas.positive_number(width, "width"),
            height: Canvas.positive_number(height, "height")
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
