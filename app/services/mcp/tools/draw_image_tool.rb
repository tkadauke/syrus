require "mcp"

module Mcp::Tools
  class DrawImageTool < MCP::Tool
    tool_name "draw_image"

    description "Append an Excalidraw image element from a data URL and persist its BinaryFiles entry."

    input_schema(
      properties: {
        data_url: { type: "string", description: "Image data URL, for example data:image/png;base64,..." },
        mime_type: { type: "string" },
        file_id: { type: "string", description: "Optional stable Excalidraw file id." },
        x: { type: "number" },
        y: { type: "number" },
        width: { type: "number" },
        height: { type: "number" }
      },
      required: %w[data_url x y width height]
    )

    class << self
      def call(data_url:, x:, y:, width:, height:, server_context:, mime_type: nil, file_id: nil)
        data_url = data_url.to_s
        return Mcp::Tools.invalid("data_url must be a data URL") unless data_url.start_with?("data:")

        args = {
          "data_url" => data_url,
          "mime_type" => mime_type,
          "file_id" => file_id,
          "x" => x,
          "y" => y,
          "width" => width,
          "height" => height
        }.compact

        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |elements, scene|
          Canvas.ensure_can_append_element!(elements)
          file = Canvas.file_record(data_url: data_url, mime_type: mime_type, file_id: file_id)
          element = Canvas.image_element(
            x: Canvas.number(x, "x"),
            y: Canvas.number(y, "y"),
            width: Canvas.positive_number(width, "width"),
            height: Canvas.positive_number(height, "height"),
            file_id: file.fetch("id")
          )
          scene["files"][file.fetch("id")] = file
          elements << element
          { id: element.fetch("id"), file_id: file.fetch("id") }
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
