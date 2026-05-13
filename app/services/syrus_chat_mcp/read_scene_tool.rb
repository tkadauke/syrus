require "mcp"

module SyrusChatMcp
  class ReadSceneTool < MCP::Tool
    tool_name "read_scene"

    description "Return the current whiteboard scene elements and version without rasterizing the canvas."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        SyrusChatMcp.success(Canvas.read(server_context.fetch(:chat_session)))
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
