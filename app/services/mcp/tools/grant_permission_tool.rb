require "mcp"
module Mcp::Tools
  class GrantPermissionTool < MCP::Tool
    extend PermissionToolSupport
    tool_name "grant_permission"
    description "Request a permanent allow rule. Always requires operator confirmation and cannot authorize itself."
    input_schema(properties: PermissionToolSupport::SUBJECT_PROPERTIES, required: %w[role subject_selector_type capability operation])
    class << self
      def call(server_context:, **payload) = permission_action(server_context, "grant_permission", payload, "Grant this permission permanently?")
    end
  end
end
