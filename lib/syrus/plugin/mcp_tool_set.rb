module Syrus
  module Plugin
    # Interface module for MCP tool set implementations.
    #
    # Include this module in any class registered as an :mcp_tool_set
    # extension point. The class must implement:
    #
    #   .tool_definitions       → [{name:, description:, input_schema:}, ...]
    #   .available_for?(repo)   → bool
    #   #handle(tool_name, params, context) → result hash
    #
    # Definitions may provide +capability_descriptor:+. A plugin may
    # temporarily ratchet legacy definitions through manifest-owned
    # +capability_descriptor_compatibility+ digests while it migrates.
    #
    # Workflow MCP tool sets may optionally implement:
    #
    #   .available_for_context?(McpToolContext) → bool
    #   .tool_definitions(context: McpToolContext) → [...]
    #
    # Use the context-aware forms when availability depends on the agent role,
    # not just on the repository.
    module McpToolSet
    end
  end
end
