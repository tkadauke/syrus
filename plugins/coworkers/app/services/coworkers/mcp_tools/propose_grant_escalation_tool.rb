require "mcp"

module Coworkers::McpTools
  class ProposeGrantEscalationTool < MCP::Tool
    extend Mcp::Tools::ProposalToolSupport
    extend Mcp::Tools::PendingActionToolSupport

    tool_name "propose_coworker_grants"
    description "Request additional capabilities for an existing coworker. No grant is added until the owner confirms."
    input_schema(
      properties: {
        coworker_id: { type: "integer" },
        grants: { type: "array", minItems: 1, items: { type: "string" } }
      },
      required: %w[coworker_id grants]
    )

    class << self
      def call(coworker_id:, grants:, server_context:)
        chat = server_context.fetch(:chat_session)
        coworker, normalized_grants = Coworkers::GrantEscalation.preflight!(
          owner: chat.user, coworker_id: coworker_id, grants: grants
        )
        payload = { "coworker_id" => coworker.id, "handle" => coworker.handle, "grants" => normalized_grants }
        pending_action = create_pending_action_for_current_message!(
          server_context, chat, action: "escalate_coworker_grants", payload: payload, requested_by: "agent"
        )
        Mcp::Tools.success(
          pending_confirmation_id: pending_action.id, pending_action_id: pending_action.id,
          state: pending_action.state, message: "Grant additional capabilities to @#{coworker.handle}?",
          grant_escalation: payload
        )
      rescue ActiveRecord::RecordNotFound
        Mcp::Tools.invalid("coworker not found")
      rescue StandardError => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
