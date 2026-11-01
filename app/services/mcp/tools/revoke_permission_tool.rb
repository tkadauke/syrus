require "mcp"
module Mcp::Tools
  class RevokePermissionTool < MCP::Tool
    extend PermissionToolSupport
    tool_name "revoke_permission"
    description "Request revocation of one of the current user's durable permission rules. Always requires operator confirmation."
    input_schema(properties: { permission_rule_id: { type: "integer" }, rationale: { type: "string", maxLength: 1000 } }, required: %w[permission_rule_id])
    class << self
      def call(permission_rule_id:, server_context:, rationale: nil) = permission_action(server_context, "revoke_permission", { permission_rule_id:, rationale: }, "Revoke this permission rule?")
    end
  end
end
