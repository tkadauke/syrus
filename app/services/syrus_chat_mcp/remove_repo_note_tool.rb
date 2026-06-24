require "mcp"

module SyrusChatMcp
  class RemoveRepoNoteTool < MCP::Tool
    extend ProposalToolSupport

    tool_name "remove_repo_note"

    description <<~DESC
      Request removal of an active repository note by id. The note is not
      removed until the operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        id: { type: "integer", description: "Repository note id to remove." }
      },
      required: %w[id]
    )

    class << self
      def call(id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        note_id = Integer(id, exception: false)
        return SyrusChatMcp.invalid("id is required") unless note_id

        note = chat_session.repository.repository_notes.active.find_by(id: note_id)
        return SyrusChatMcp.invalid("unknown active repository note id: #{id}") unless note

        pending_action = create_pending_action_message!(
          chat_session,
          action: "remove_repo_note",
          payload: { "id" => note.id },
          requested_by: "agent"
        )

        SyrusChatMcp.success(
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Repository note removal requires operator confirmation."
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
