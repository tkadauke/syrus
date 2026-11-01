require "mcp"

module Mcp::Tools
  class DiscoverCoworkerCapabilitiesTool < MCP::Tool
    tool_name "discover_coworker_capabilities"
    description "Discover capability families this coworker may request. Returns required scope, effective policy, and the reason each capability is locked; it does not grant authority."
    input_schema(properties: {
      query: { type: "string", description: "Optional capability or operation search text." },
      include_non_requestable: { type: "boolean", default: false,
        description: "Also include available and prohibited families with their distinct state." }
    })

    class << self
      def call(server_context:, query: nil, include_non_requestable: false)
        context = McpToolContext.from_server_context(server_context)
        unless context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
          return Mcp::Tools.not_authorized
        end

        capabilities = Permissions::CoworkerCapabilityDiscovery.new(context)
          .call(query:, include_non_requestable:)
          .map(&:to_h)
        Mcp::Tools.success(capabilities: capabilities, states: %w[available requestable prohibited plugin_disabled resource_unconfigured unavailable])
      end
    end
  end
end
