require "mcp"

module Mcp::Tools
  class ExplainPermissionTool < MCP::Tool
    extend PermissionToolSupport
    tool_name "explain_permission"
    description "Explain the effective policy chain for a capability invocation without changing authority."
    input_schema(properties: {
      capability: { type: "string" }, operation: { type: "string" }, role: { type: "string" },
      resource_scope: { type: "object" }, arguments: { type: "object" },
      subject_selector_type: { type: "string" }, subject_selector_id: { type: "string" },
      subject_repository_id: { type: "integer" }, chat_session_id: { type: "integer" },
      job_id: { type: "integer" }
    }, required: %w[capability operation role])

    class << self
      def call(capability:, operation:, role:, server_context:, resource_scope: {}, arguments: {}, **selectors)
        descriptor = Permissions::Catalog.find!(capability:, operation:)
        service = management(server_context)
        context = selectors.compact.transform_keys(&:to_sym).merge(role: role.to_s)
        decision = service.explain(descriptor:, role:, resource_scope:, arguments:, context:)
        Mcp::Tools.success(decision.to_h)
      rescue Permissions::Catalog::UnknownCapability, ArgumentError => error
        Mcp::Tools.invalid(error.message)
      end
    end
  end
end
