require "mcp"

module Whiteboard
  class DrawTextTool < MCP::Tool
    tool_name "draw_text"

    description "Append a text element to the whiteboard scene."

    input_schema(
      properties: {
        content: { type: "string" },
        x: { type: "number" },
        y: { type: "number" },
        font_size: { type: "integer" }
      },
      required: %w[content x y]
    )

    class << self
      def call(content:, x:, y:, server_context:, font_size: nil)
        content = content.to_s
        return Syrus::Host::McpTools.invalid("content is required") if content.empty?

        args = {
          "content" => content,
          "x" => Canvas.number(x, "x"),
          "y" => Canvas.number(y, "y"),
          "font_size" => font_size
        }.compact

        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |elements|
          Canvas.ensure_can_append_element!(elements)
          element = Canvas.text_element(**args.symbolize_keys)
          elements << element
          { id: element.fetch("id") }
        end

        Syrus::Host::McpTools.success(result)
      rescue Canvas::ElementLimitExceeded => e
        Syrus::Host::McpTools.tool_error(e.message)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        Syrus::Host::McpTools.invalid(e.message)
      end
    end
  end
end
