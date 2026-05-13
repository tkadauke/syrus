require "mcp"

module SyrusChatMcp
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
        return SyrusChatMcp.invalid("content is required") if content.empty?

        args = {
          "content" => content,
          "x" => Canvas.number(x, "x"),
          "y" => Canvas.number(y, "y"),
          "font_size" => font_size
        }.compact

        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |elements|
          element = Canvas.text_element(**args.symbolize_keys)
          elements << element
          { id: element.fetch("id") }
        end

        SyrusChatMcp.success(result)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.message)
      end
    end
  end
end
