require "mcp"

module SyrusChatMcp
  class UpdateSceneTool < MCP::Tool
    tool_name "update_scene"

    description "Replace the whiteboard scene elements array. Use only when high-level tools cannot express the change."

    input_schema(
      properties: {
        elements: { type: "array", items: { type: "object" } }
      },
      required: %w[elements]
    )

    class << self
      def call(elements:, server_context:)
        Canvas.validate_elements!(elements)

        args = { "elements" => elements }
        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |current_elements|
          current_elements.replace(Canvas.deep_dup_elements(elements))
          { replaced: true }
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
