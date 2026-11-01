require "mcp"
module Mcp::Tools
  class CancelAuthorizationRequestTool < MCP::Tool
    extend PermissionToolSupport
    tool_name "cancel_authorization_request"
    description "Request cancellation of an obsolete authorization request without creating a deny rule. Always requires operator confirmation."
    input_schema(properties: { authorization_request_id: { type: "integer" }, rationale: { type: "string", maxLength: 1000 } }, required: %w[authorization_request_id])
    class << self
      def call(authorization_request_id:, server_context:, rationale: nil) = permission_action(server_context, "cancel_authorization_request", { authorization_request_id:, rationale: }, "Cancel this authorization request?")
    end
  end
end
