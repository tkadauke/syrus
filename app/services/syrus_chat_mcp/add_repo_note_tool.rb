require "mcp"

module SyrusChatMcp
  class AddRepoNoteTool < MCP::Tool
    extend ProposalToolSupport

    tool_name "add_repo_note"

    description <<~DESC
      Request that the operator pin a repository note. The note is not
      created until the operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        body: { type: "string", description: "Short repository-scoped note to pin." }
      },
      required: %w[body]
    )

    class << self
      def call(body:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        body = body.to_s.strip
        return SyrusChatMcp.invalid("body is required") if body.empty?

        pending_action = create_pending_action_message!(
          chat_session,
          action: "add_repo_note",
          payload: { "body" => body },
          requested_by: "agent"
        )

        SyrusChatMcp.success(
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Repository note requires operator confirmation."
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
