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
    module McpToolSet
    end
  end
end
