require "mcp"

module Mcp::Tools
  class UpdateEpicTool < MCP::Tool
    extend EpicToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "update_epic"

    description "Update the title and/or description for an Epic."

    input_schema(
      properties: {
        epic_id: { type: "integer", description: "Syrus Epic id to update." },
        title: { type: "string", description: "New Epic title." },
        description: { type: "string", description: "New Epic description." }
      },
      required: %w[epic_id]
    )

    class << self
      def call(epic_id:, server_context:, title: nil, description: nil)
        epic_id = normalize_epic_id(epic_id)
        return Mcp::Tools.invalid("epic_id is required") unless epic_id

        attrs = {}
        attrs[:title] = title if title
        attrs[:description] = description if description
        return Mcp::Tools.invalid("title or description is required") if attrs.empty?

        epic = find_epic!(epic_id)
        return Mcp::Tools.invalid("archived epics cannot be updated") if epic.archived?

        epic.update!(attrs)

        Mcp::Tools.success(compact_epic_payload(epic.reload))
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
