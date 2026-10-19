require "mcp"

module Whiteboard
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
        return Mcp::Tools.invalid("id is required") if id.empty?

        args = { "id" => id }
        result = Canvas.mutate(server_context.fetch(:chat_session), tool_name, args) do |elements|
          element = elements.find { |candidate| candidate["id"] == id }
          label_id = Array(element&.fetch("boundElements", nil)).find { |bound| bound["type"] == "text" }&.fetch("id", nil)
          label = elements.find { |candidate| candidate["id"] == label_id }&.fetch("text", nil)
          Canvas.remove_element!(elements, id)
          { id: id, type: element&.fetch("type", nil), label: label }.compact
        end

        Mcp::Tools.success(result)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
