require "mcp"

module Mcp::Tools
  class ListPermissionsTool < MCP::Tool
    extend PermissionToolSupport
    tool_name "list_permissions"
    description "List the current user's durable permission rules and temporary leases. This is read-only."
    input_schema(properties: { include_inactive: { type: "boolean", default: false } })

    class << self
      def call(server_context:, include_inactive: false)
        service = management(server_context)
        Mcp::Tools.success(
          rules: service.rules(active: !include_inactive).map { |rule| serialize_rule(rule) },
          leases: service.leases(active: !include_inactive).map { |lease| serialize_lease(lease) }
        )
      end
    end
  end
end
