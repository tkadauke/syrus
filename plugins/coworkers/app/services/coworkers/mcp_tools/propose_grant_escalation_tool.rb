require "mcp"

module Coworkers::McpTools
  class ProposeGrantEscalationTool < MCP::Tool
    extend Mcp::Tools::ProposalToolSupport
    extend Mcp::Tools::PendingActionToolSupport

    tool_name "propose_coworker_grants"
    description "Propose grant policy or scope changes for a coworker owned by the signed-in user. Use policy off to remove a grant. Nothing changes until the owner confirms."
    input_schema(
      properties: {
        coworker_id: { type: "integer" }, handle: { type: "string" },
        grants: {
          type: "array", minItems: 1,
          items: {
            type: "object",
            properties: { capability: { type: "string" }, policy: { type: "string", enum: Coworkers::GrantCatalog::POLICY_RANK.keys }, scope: {} },
            required: %w[capability policy]
          }
        }
      },
      required: %w[grants],
      oneOf: [ { required: [ "coworker_id" ] }, { required: [ "handle" ] } ]
    )

    class << self
      def call(grants:, server_context:, coworker_id: nil, handle: nil)
        chat = server_context.fetch(:chat_session)
        coworker = Coworkers::OwnerResolver.new(owner: chat.user).find!(id: coworker_id, handle: handle)
        normalized_grants = normalize_grants(grants, owner: chat.user, coworker: coworker)
        payload = { "coworker_id" => coworker.id, "handle" => coworker.handle, "grants" => normalized_grants }
        pending_action = create_pending_action_for_current_message!(
          server_context, chat, action: "escalate_coworker_grants", payload: payload, requested_by: "agent"
        )
        Mcp::Tools.success(
          pending_confirmation_id: pending_action.id, pending_action_id: pending_action.id,
          state: pending_action.state, message: "Change grants for @#{coworker.handle}?",
          grant_escalation: payload
        )
      rescue ActiveRecord::RecordNotFound
        Mcp::Tools.invalid("coworker not found")
      rescue StandardError => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def normalize_grants(grants, owner:, coworker:)
        held_grants = coworker.grants.index_by(&:capability)
        normalized = Array(grants).map do |raw|
          attributes = raw.to_h.stringify_keys
          descriptor = Coworkers::GrantCatalog.fetch(attributes.fetch("capability"))
          policy = attributes.fetch("policy").to_s
          Coworkers::PrivilegedGrantGate.ensure_available!(descriptor) unless policy == "off"
          raise ArgumentError, "approval policy exceeds maximum #{descriptor.maximum_policy}" unless Coworkers::GrantCatalog.policy_allowed?(descriptor, policy)
          scope = attributes.key?("scope") ? attributes["scope"] : Coworkers::GrantUpdate::SCOPE_UNCHANGED
          if policy != "off" && descriptor.scopeable? && scope.equal?(Coworkers::GrantUpdate::SCOPE_UNCHANGED) && held_grants[descriptor.name].nil?
            raise ArgumentError, "scope is required for #{descriptor.name}"
          end
          unless policy == "off" || scope.equal?(Coworkers::GrantUpdate::SCOPE_UNCHANGED) || descriptor.valid_scope?(scope, user: owner)
            raise ArgumentError, "invalid scope for #{descriptor.name}"
          end
          { "capability" => descriptor.name, "policy" => policy }.tap { |entry| entry["scope"] = scope unless scope.equal?(Coworkers::GrantUpdate::SCOPE_UNCHANGED) }
        end
        raise ArgumentError, "grants must not be empty" if normalized.empty?
        raise ArgumentError, "duplicate grants are not allowed" if normalized.pluck("capability").uniq.length != normalized.length
        normalized
      end
    end
  end
end
