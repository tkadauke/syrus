require "mcp"

module SyrusChatMcp
  class RemoveEpicDependencyTool < MCP::Tool
    extend EpicToolSupport

    tool_name "remove_epic_dependency"

    description "Remove an Epic dependency between two Epics in this chat session's repository."

    input_schema(
      properties: {
        epic_id: { type: "integer", description: "Syrus Epic id to update." },
        depends_on_epic_id: { type: "integer", description: "Syrus Epic id to remove as a dependency." }
      },
      required: %w[epic_id depends_on_epic_id]
    )

    class << self
      def call(epic_id:, depends_on_epic_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        epic_id = normalize_epic_id(epic_id)
        depends_on_epic_id = normalize_epic_id(depends_on_epic_id)
        return SyrusChatMcp.invalid("epic_id is required") unless epic_id
        return SyrusChatMcp.invalid("depends_on_epic_id is required") unless depends_on_epic_id

        epic = find_repository_epic(chat_session, epic_id)
        return epic_not_found(epic_id) unless epic

        depends_on_epic = find_repository_epic(chat_session, depends_on_epic_id)
        return epic_not_found(depends_on_epic_id) unless depends_on_epic

        EpicDependency.where(epic: epic, depends_on_epic: depends_on_epic).destroy_all

        SyrusChatMcp.success(epic_id: epic.id, depends_on: epic.reload.depends_on_epics.order(:id).pluck(:id))
      end
    end
  end
end
