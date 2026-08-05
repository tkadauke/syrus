require "mcp"

module SyrusChatMcp
  class ClearProviderCircuitTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "clear_provider_circuit"
    description "Request an audited clear/shorten of provider-circuit state by recording newer positive provider evidence. Refuses unrepaired structured quota evidence. Requires operator confirmation."

    input_schema(
      properties: {
        provider: { type: "string", description: "Agent provider, such as codex or claude." },
        user_id: { type: "integer", description: "User whose provider availability evidence should be repaired." },
        mode: { type: "string", enum: ProviderCircuitClearance::MODES, description: "clear or shorten." },
        positive_evidence: { type: "string", description: "Concrete newer positive evidence or explicit operator confirmation." },
        retry_after: { type: "string", description: "Optional ISO8601/string timestamp documenting a shortened retry time." },
        reason: { type: "string", description: "Operator-facing audit reason." }
      },
      required: %w[provider user_id positive_evidence reason]
    )

    class << self
      def call(provider:, user_id:, positive_evidence:, reason:, mode: "clear", retry_after: nil, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        user_id = integer_param(user_id, "user_id")
        return user_id if user_id.is_a?(MCP::Tool::Response)
        target_user = User.find_by(id: user_id)
        return SyrusChatMcp.invalid("user not found: #{user_id}") unless target_user
        return SyrusChatMcp.invalid("structured quota evidence is still open for #{provider}") if structured_quota_evidence?(target_user, provider)

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "clear_provider_circuit",
          payload: {
            "provider" => provider.to_s,
            "user_id" => target_user.id,
            "mode" => mode.to_s.presence || "clear",
            "positive_evidence" => positive_evidence.to_s,
            "retry_after" => retry_after
          }.compact,
          reason: reason,
          message: "#{mode.to_s.presence || "clear"} #{provider} provider circuit evidence for user ##{target_user.id}?"
        )
      end

      private

      def structured_quota_evidence?(user, provider)
        ProviderAvailabilityEvidence
          .where(user: user, provider: provider.to_s, status: %w[exhausted warning], source: "usage_probe")
          .unrepaired_for_circuit
          .where("observed_at >= ?", ProviderCircuitBreaker::USAGE_LIMIT_WINDOW.ago)
          .any? { |evidence| evidence.details.to_h["snapshot"].present? }
      end
    end
  end
end
