require "mcp"

module Mcp::Tools
  class ArchiveEpicTool < MCP::Tool
    extend EpicToolSupport
    extend ProposalToolSupport
    extend PendingActionToolSupport

    tool_name "archive_epic"

    description <<~DESC
      Request archival of an Epic in this repository. Archiving an Epic closes
      its open child Jobs, so the Epic is not archived until the operator
      confirms the pending action.
    DESC

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
        return Mcp::Tools.invalid("epic_id is required") unless epic_id

        epic = find_repository_epic(chat_session, epic_id)
        return epic_not_found(epic_id) unless epic
        return Mcp::Tools.invalid("epic is already archived") if epic.archived?

        create_pending_action!(
          server_context,
          chat_session,
          action: "archive_epic",
          payload: { "epic_id" => epic.id },
          message: "Archive #{epic.slug}? Open child Jobs will be cancelled and closed when confirmed."
        )
      end
    end
  end
end
