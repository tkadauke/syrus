require "mcp"

module Mcp::Tools
  class UnlandEpicTool < MCP::Tool
    extend ProposalToolSupport
    extend AuthorizationSupport
    extend EpicToolSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "unland_epic"
    description "Preflight or request an operator-confirmed coordinated unland of a landed Epic. Confirmation creates one linked rollback Job and does not roll back deployments."
    input_schema(properties: { epic_id: { type: "integer" }, dry_run: { type: "boolean", default: false } }, required: %w[epic_id])

    class << self
      def call(epic_id:, server_context:, dry_run: false)
        chat = server_context.fetch(:chat_session)
        epic = find_repository_epic(chat, normalize_epic_id(epic_id))
        return epic_not_found(epic_id) unless epic
        plan = Unlanding::Create.plan!(original: epic, user: chat.user)
        return Mcp::Tools.success(plan.to_h) if dry_run

        pending = create_pending_action_for_current_message!(server_context, chat, action: "unland_epic", payload: { "epic_id" => epic.id, "plan" => plan.to_h }, requested_by: "agent")
        Mcp::Tools.success(plan.to_h.merge(pending_confirmation_id: pending.id, pending_action_id: pending.id, state: pending.state, message: "Unland #{epic.slug}? Operator confirmation is required."))
      rescue Unlanding::Create::Ineligible => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
