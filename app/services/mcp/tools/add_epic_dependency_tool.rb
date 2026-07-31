require "mcp"

module Mcp::Tools
  class AddEpicDependencyTool < MCP::Tool
    extend EpicToolSupport

    tool_name "add_epic_dependency"

    description "Add an Epic dependency between two Epics in this chat session's repository."

    input_schema(
      properties: {
        epic_id: { type: "integer", description: "Syrus Epic id to update." },
        depends_on_epic_id: { type: "integer", description: "Syrus Epic id that must land first." }
      },
      required: %w[epic_id depends_on_epic_id]
    )

    class << self
      def call(epic_id:, depends_on_epic_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        epic_id = normalize_epic_id(epic_id)
        depends_on_epic_id = normalize_epic_id(depends_on_epic_id)
        return Mcp::Tools.invalid("epic_id is required") unless epic_id
        return Mcp::Tools.invalid("depends_on_epic_id is required") unless depends_on_epic_id

        epic = find_repository_epic(chat_session, epic_id)
        return epic_not_found(epic_id) unless epic

        depends_on_epic = find_repository_epic(chat_session, depends_on_epic_id)
        return epic_not_found(depends_on_epic_id) unless depends_on_epic

        EpicDependency.find_or_create_by!(
          epic: epic,
          depends_on_epic: depends_on_epic,
          derived: false
        )

        Mcp::Tools.success(epic_id: epic.id, depends_on: depends_on_ids(epic.reload))
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def depends_on_ids(epic)
        epic.depends_on_epics.order(:id).pluck(:id)
      end
    end
  end
end
