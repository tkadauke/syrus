require "mcp"

module SyrusChatMcp
  class ClearCanvasTool < MCP::Tool
    tool_name "clear_canvas"

    description "Remove all elements from the whiteboard scene."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, {}) do |elements|
          elements.clear
          { cleared: true }
        end

        SyrusChatMcp.success(result)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.message)
      end
    end
  end
end
