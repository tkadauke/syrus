require "mcp"
module Mcp::Tools
  class RevokePermissionLeaseTool < MCP::Tool
    extend PermissionToolSupport
    tool_name "revoke_permission_lease"
    description "Request revocation of one of the current user's permission leases. Always requires operator confirmation."
    input_schema(properties: { permission_lease_id: { type: "integer" }, rationale: { type: "string", maxLength: 1000 } }, required: %w[permission_lease_id])
    class << self
      def call(permission_lease_id:, server_context:, rationale: nil) = permission_action(server_context, "revoke_permission_lease", { permission_lease_id:, rationale: }, "Revoke this permission lease?")
    end
  end
end
