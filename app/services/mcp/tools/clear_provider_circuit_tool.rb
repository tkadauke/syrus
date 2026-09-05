require "mcp"

module Mcp::Tools
  class ClearProviderCircuitTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "clear_provider_circuit"
    description <<~DESC
      Request an audited clear/shorten of provider-circuit state by
      recording newer positive provider evidence. Refuses unrepaired
      structured quota evidence. Pass user_id for a single user (unchanged
      single-confirmation behavior) or user_ids for multiple users sharing
      one provider/mode/positive_evidence/reason (the root cause behind
      clearing every user's circuit in the batch), which creates one
      grouped pending action the operator confirms or rejects together.
      Requires operator confirmation.
    DESC

    input_schema(
      properties: {
        provider: { type: "string", description: "Agent provider, such as codex or claude." },
        user_id: { type: "integer", description: "User whose provider availability evidence should be repaired." },
        user_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple user ids to repair as one grouped pending action, sharing one provider/mode/positive_evidence/reason."
        },
        mode: { type: "string", enum: ProviderCircuitClearance::MODES, description: "clear or shorten." },
        positive_evidence: { type: "string", description: "Concrete newer positive evidence or explicit operator confirmation." },
        retry_after: { type: "string", description: "Optional ISO8601/string timestamp documenting a shortened retry time." },
        reason: { type: "string", description: "Operator-facing audit reason." }
      },
      required: %w[provider positive_evidence reason]
    )

    class << self
      def call(provider:, positive_evidence:, reason:, user_id: nil, user_ids: nil, mode: "clear", retry_after: nil, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        ids, bulk, error = resolve_ids(id: user_id, ids: user_ids, param_name: "user_id")
        return error if error

        users = ids.map { |id| User.find_by(id: id) }
        missing = ids.zip(users).select { |_id, user| user.nil? }.map(&:first)
        return Mcp::Tools.invalid("user not found: #{missing.join(', ')}") if missing.any?
        blocked = users.select { |user| structured_quota_evidence?(user, provider) }
        return Mcp::Tools.invalid("structured quota evidence is still open for #{provider}: #{blocked.map(&:id).join(', ')}") if blocked.any?

        payload_for = lambda do |user|
          {
            "provider" => provider.to_s,
            "user_id" => user.id,
            "mode" => mode.to_s.presence || "clear",
            "positive_evidence" => positive_evidence.to_s,
            "retry_after" => retry_after
          }.compact
        end

        unless bulk
          target_user = users.first
          return create_pending_admin_action(
            server_context: server_context,
            chat_session: chat_session,
            action: "clear_provider_circuit",
            payload: payload_for.call(target_user),
            reason: reason,
            message: "#{mode.to_s.presence || "clear"} #{provider} provider circuit evidence for user ##{target_user.id}?"
          )
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: users.map { |user|
            { action: "clear_provider_circuit", payload: payload_for.call(user), requested_by: "agent", reason: reason }
          },
          reason: reason
        )
        bulk_action_response(group: group, message: "#{mode.to_s.presence || "clear"} #{provider} provider circuit evidence for #{users.size} users?")
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
