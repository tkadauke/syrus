require "mcp"

module Mcp::Tools
  class RequestPermissionRevocationTool < MCP::Tool
    tool_name "request_permission_revocation"
    description "Ask the owner to revoke a durable permission rule that applies to you. This only creates an " \
      "owner-confirmed request; the rule is not revoked or edited until the owner confirms."
    input_schema(properties: { permission_rule_id: { type: "integer" }, rationale: { type: "string", maxLength: 1000 } },
      required: %w[permission_rule_id])

    class << self
      def call(server_context:, permission_rule_id:, rationale: nil)
        context = McpToolContext.from_server_context(server_context)
        result = Permissions::CoworkerPermissionRevocationRequest.new(
          context:, permission_rule_id:, rationale:, origin_message: server_context[:current_message]
        ).call
        Mcp::Tools.success(status: result.status.to_s, pending_action_id: result.pending_action.id, revoked: false,
          message: I18n.t("server.permissions.coworker_permission.revocation_requested"))
      rescue Permissions::CoworkerPermissionRequest::Rejected => error
        Mcp::Tools.invalid("#{error.code}: #{error.message}")
      end
    end
  end
end
