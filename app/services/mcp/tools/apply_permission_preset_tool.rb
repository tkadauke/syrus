require "mcp"
module Mcp::Tools
  class ApplyPermissionPresetTool < MCP::Tool
    extend PermissionToolSupport
    tool_name "apply_permission_preset"
    description "Request a provider-declared permission preset by capability and preset name. Always requires operator confirmation."
    input_schema(properties: PermissionToolSupport::SUBJECT_PROPERTIES.merge(preset: { type: "string" }), required: %w[role subject_selector_type capability operation preset])
    class << self
      def call(server_context:, **payload) = permission_action(server_context, "apply_permission_preset", payload, "Apply this permission preset?")
    end
  end
end
