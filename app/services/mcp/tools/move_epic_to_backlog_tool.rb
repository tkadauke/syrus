require "mcp"

module Mcp::Tools
  class MoveEpicToBacklogTool < MCP::Tool
    extend EpicToolSupport

    tool_name "move_epic_to_backlog"

    description "Move a ready Epic in this repository back to backlog."

    input_schema(
      properties: {
        epic_id: { type: "integer", description: "Syrus Epic id to move back to backlog." }
      },
      required: %w[epic_id]
    )

    class << self
      def call(epic_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        epic_id = normalize_epic_id(epic_id)
        return Mcp::Tools.invalid("epic_id is required") unless epic_id

        epic = find_repository_epic(chat_session, epic_id)
        return epic_not_found(epic_id) unless epic
        return Mcp::Tools.invalid("epic must be ready to move to backlog; current state is #{epic.state}") unless epic.ready?

        previous_state = epic.state
        epic.move_to_backlog!

        Mcp::Tools.success(epic_id: epic.id, previous_state: previous_state, new_state: epic.reload.state)
      end
    end
  end
end
