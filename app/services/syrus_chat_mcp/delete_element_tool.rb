require "mcp"

module SyrusChatMcp
  class DeleteElementTool < MCP::Tool
    tool_name "delete_element"

    description "Remove one element from the whiteboard scene."

    input_schema(
      properties: {
        id: { type: "string" }
      },
      required: %w[id]
    )

    class << self
      def call(id:, server_context:)
        id = id.to_s
        return SyrusChatMcp.invalid("id is required") if id.empty?

        args = { "id" => id }
        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |elements|
          Canvas.remove_element!(elements, id)
          { id: id }
        end

        SyrusChatMcp.success(result)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.message)
      end
    end
  end
end
