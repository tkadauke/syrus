module Prompts
  module WorkflowMcpToolInstructions
    SERVER_NAME = "syrus-mcp-sidecar"

    def self.claude_tool_name(tool_name)
      "mcp__#{SERVER_NAME}__#{tool_name}"
    end

    def self.codex_tool_name(tool_name)
      "#{SERVER_NAME}.#{tool_name}"
    end

    def self.tool_name_for(provider, tool_name)
      AgentProviders.for(provider).mcp_tool_name(tool_name, server_name: SERVER_NAME)
    rescue AgentProviders::ConfigurationError
      nil
    end
  end
end
