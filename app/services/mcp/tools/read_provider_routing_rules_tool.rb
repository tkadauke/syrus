require "mcp"

module Mcp::Tools
  class ReadProviderRoutingRulesTool < MCP::Tool
    extend ProviderRoutingToolSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "read_provider_routing_rules"
    description "Read an ordered provider-routing rule set, inherited context, registry options, active holds, and its revision. User scope always means the current user; arbitrary user ids are not accepted."

    input_schema(
      properties: {
        scope_type: { type: "string", enum: %w[user repository job] },
        repository_id: { type: "integer" },
        job_id: { type: "integer" }
      },
      required: %w[scope_type]
    )

    class << self
      def call(scope_type:, server_context:, repository_id: nil, job_id: nil)
        Mcp::Tools.success(provider_routing_rule_set!(scope_type: scope_type, repository_id: repository_id, job_id: job_id).snapshot)
      rescue ProviderRouting::RuleSet::InvalidOperation => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
