require "mcp"

module SyrusChatMcp
  class UpdateEpicTool < MCP::Tool
    extend EpicToolSupport

    tool_name "update_epic"

    description "Update the title and/or description for an Epic in this repository."

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
        chat_session = server_context.fetch(:chat_session)
        epic_id = normalize_epic_id(epic_id)
        return SyrusChatMcp.invalid("epic_id is required") unless epic_id

        attrs = {}
        attrs[:title] = title if title
        attrs[:description] = description if description
        return SyrusChatMcp.invalid("title or description is required") if attrs.empty?

        epic = find_repository_epic(chat_session, epic_id)
        return epic_not_found(epic_id) unless epic
        return SyrusChatMcp.invalid("archived epics cannot be updated") if epic.archived?

        epic.update!(attrs)

        SyrusChatMcp.success(compact_epic_payload(epic.reload))
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
