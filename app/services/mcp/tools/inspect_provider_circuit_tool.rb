require "mcp"

module Mcp::Tools
  class InspectProviderCircuitTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "inspect_provider_circuit"
    description "Inspect provider-circuit evidence, failed Runs, diagnostics, classifications, retry timing, and blocked consumers. Admin/Supervisor only; read-only."

    input_schema(
      properties: {
        provider: { type: "string", description: "Agent provider, such as codex or claude." },
        user_id: { type: "integer", description: "Optional user id to scope user-specific evidence and consumers." }
      },
      required: %w[provider]
    )

    class << self
      def call(provider:, user_id: nil, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        parsed_user_id = user_id.present? ? integer_param(user_id, "user_id") : nil
        return parsed_user_id if parsed_user_id.is_a?(MCP::Tool::Response)
        target_user = parsed_user_id.present? ? User.find_by(id: parsed_user_id) : nil
        return Mcp::Tools.invalid("user not found: #{user_id}") if user_id.present? && !target_user

        Mcp::Tools.success(ProviderCircuitInspector.call(provider: provider, user: target_user))
      end
    end
  end
end
