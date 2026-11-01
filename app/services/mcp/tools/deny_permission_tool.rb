require "mcp"
module Mcp::Tools
  class DenyPermissionTool < MCP::Tool
    extend PermissionToolSupport
    tool_name "deny_permission"
    description "Request a durable deny rule. Always requires operator confirmation."
    input_schema(properties: PermissionToolSupport::SUBJECT_PROPERTIES, required: %w[role subject_selector_type capability operation])
    class << self
      def call(server_context:, **payload) = permission_action(server_context, "deny_permission", payload, "Deny this permission permanently?")
    end
  end
end
