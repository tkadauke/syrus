require "mcp"

module Mcp::Tools
  class StartEpicTool < MCP::Tool
    extend EpicToolSupport

    tool_name "start_epic"

    description "Move a ready Epic in this repository to in_progress and release its child Jobs."

    input_schema(
      properties: {
        epic_id: { type: "integer", description: "Syrus Epic id to start." }
      },
      required: %w[epic_id]
    )

    class << self
      def call(epic_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        epic_id = normalize_epic_id(epic_id)
        return Mcp::Tools.invalid("epic_id is required") unless epic_id
        actor = Current.user || chat_session.user
        if actor&.product_owner?
          return Mcp::Tools.invalid("Product owners cannot advance Epics beyond backlog.")
        end

        epic = find_repository_epic(chat_session, epic_id)
        return epic_not_found(epic_id) unless epic
        return Mcp::Tools.invalid("epic must be ready to start; current state is #{epic.state}") unless epic.ready?

        previous_state = epic.state
        epic.start!(actor: actor)

        Mcp::Tools.success(epic_id: epic.id, previous_state: previous_state, new_state: epic.reload.state)
      end
    end
  end
end
