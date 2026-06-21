require "mcp"

module SyrusChatMcp
  class ArchiveEpicTool < MCP::Tool
    extend EpicToolSupport

    tool_name "archive_epic"

    description "Archive an Epic in this repository."

    input_schema(
      properties: {
        epic_id: { type: "integer", description: "Syrus Epic id to archive." }
      },
      required: %w[epic_id]
    )

    class << self
      def call(epic_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        epic_id = normalize_epic_id(epic_id)
        return SyrusChatMcp.invalid("epic_id is required") unless epic_id

        epic = find_repository_epic(chat_session, epic_id)
        return epic_not_found(epic_id) unless epic
        return SyrusChatMcp.invalid("epic is already archived") if epic.archived?

        previous_state = epic.state
        epic.archive!

        SyrusChatMcp.success(epic_id: epic.id, previous_state: previous_state, new_state: epic.reload.state)
      end
    end
  end
end
