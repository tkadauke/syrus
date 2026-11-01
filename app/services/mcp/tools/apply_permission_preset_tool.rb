require "mcp"
module Mcp::Tools
  class ApplyPermissionPresetTool < MCP::Tool
    extend PermissionToolSupport
    tool_name "apply_permission_preset"
    description "Request a provider-declared permission preset by name. The complete rule draft always requires operator confirmation."
    input_schema(properties: PermissionToolSupport::SUBJECT_PROPERTIES.merge(preset: { type: "string" }), required: %w[subject_selector_type preset])
    class << self
      def call(server_context:, **payload)
        payload = payload.compact.stringify_keys
        drafts = management(server_context).preset_drafts(payload)
        permission_action(
          server_context,
          "apply_permission_preset",
          payload.merge("drafts" => drafts),
          "Apply this permission preset?"
        )
      rescue Permissions::Catalog::UnknownCapability, ActiveRecord::RecordNotFound, ArgumentError => error
        Mcp::Tools.invalid(error.message)
      end
    end
  end
end
