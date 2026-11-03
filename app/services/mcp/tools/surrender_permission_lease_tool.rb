require "mcp"

module Mcp::Tools
  class SurrenderPermissionLeaseTool < MCP::Tool
    tool_name "surrender_permission_lease"
    description "Immediately give up one of your own active temporary permission leases. Only a lease whose exact " \
      "subject is you can be surrendered; reducing your own authority needs no owner confirmation."
    input_schema(properties: { permission_lease_id: { type: "integer" } }, required: %w[permission_lease_id])

    class << self
      def call(server_context:, permission_lease_id:)
        context = McpToolContext.from_server_context(server_context)
        lease = Permissions::CoworkerLeaseSurrender.new(context:).call(permission_lease_id)
        Mcp::Tools.success(permission_lease_id: lease.id, revoked: true,
          message: I18n.t("server.permissions.coworker_permission.surrendered"))
      rescue Permissions::CoworkerPermissionRequest::Rejected => error
        Mcp::Tools.invalid("#{error.code}: #{error.message}")
      end
    end
  end
end
