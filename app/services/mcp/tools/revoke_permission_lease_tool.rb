require "mcp"
module Mcp::Tools
  class RevokePermissionLeaseTool < MCP::Tool
    extend PermissionToolSupport
    tool_name "revoke_permission_lease"
    description "Revoke one of the current user's permission leases. Revoking only reduces authority, " \
                "so it takes effect immediately without operator confirmation."
    input_schema(properties: { permission_lease_id: { type: "integer" }, rationale: { type: "string", maxLength: 1000 } }, required: %w[permission_lease_id])
    class << self
      # An essential authority reduction: acts directly, never through a card.
      def call(permission_lease_id:, server_context:, rationale: nil)
        chat = server_context.fetch(:chat_session)
        management = management(server_context)
        lease = management.leases(active: false).find(permission_lease_id)
        management.revoke_lease!(lease.id, actor: chat.user)
        Mcp::Tools.success(revoked: true, permission_lease: serialize_lease(lease.reload), rationale:)
      rescue ActiveRecord::RecordNotFound
        Mcp::Tools.invalid("permission lease not found")
      rescue ArgumentError => error
        Mcp::Tools.invalid(error.message)
      end
    end
  end
end
