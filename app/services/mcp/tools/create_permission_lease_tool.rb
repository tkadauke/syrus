require "mcp"
module Mcp::Tools
  class CreatePermissionLeaseTool < MCP::Tool
    extend PermissionToolSupport
    tool_name "create_permission_lease"
    description "Request temporary invocation, chat-session, or Job authority. Always requires operator confirmation."
    input_schema(properties: PermissionToolSupport::SUBJECT_PROPERTIES.merge(
      duration: { type: "string", enum: PermissionLease::DURATION_KINDS }, chat_session_id: { type: "integer" },
      job_id: { type: "integer" }, expires_at: { type: "string" },
      max_uses: { type: "integer", minimum: 1 }, arguments: { type: "object" }
    ), required: %w[role subject_selector_type capability operation duration])
    class << self
      def call(server_context:, **payload) = permission_action(server_context, "create_permission_lease", payload, "Create this temporary permission lease?")
    end
  end
end
