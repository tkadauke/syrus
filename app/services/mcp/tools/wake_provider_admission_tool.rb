require "mcp"

module Mcp::Tools
  class WakeProviderAdmissionTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "wake_provider_admission"
    description "Request a provider-specific admission wake after provider evidence repair. Rechecks queued Workflows with no Runs and delayed auto-retries without bypassing guards. Requires operator confirmation."

    input_schema(
      properties: {
        provider: { type: "string", description: "Agent provider, such as codex or claude." },
        user_id: { type: "integer", description: "Optional user id scope." },
        reason: { type: "string", description: "Operator-facing audit reason." }
      },
      required: %w[provider reason]
    )

    class << self
      def call(provider:, reason:, user_id: nil, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        parsed_user_id = user_id.present? ? integer_param(user_id, "user_id") : nil
        return parsed_user_id if parsed_user_id.is_a?(MCP::Tool::Response)
        target_user = parsed_user_id.present? ? User.find_by(id: parsed_user_id) : nil
        return Mcp::Tools.invalid("user not found: #{user_id}") if parsed_user_id.present? && !target_user

        preview = ProviderAdmissionWakeup.preview(provider: provider, user: target_user)
        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "wake_provider_admission",
          payload: {
            "provider" => provider.to_s,
            "user_id" => target_user&.id,
            "observed_preview" => preview.as_json
          }.compact,
          reason: reason,
          message: "Wake #{preview.workflow_count} queued #{provider} workflows and #{preview.auto_retry_count} delayed auto-retries?"
        )
      end
    end
  end
end
