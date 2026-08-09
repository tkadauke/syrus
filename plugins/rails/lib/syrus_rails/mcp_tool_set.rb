module SyrusRails
  # Placeholder — Rails-specific MCP tools (schema reader, migration explainer,
  # route lister) will be implemented in a follow-up Epic job.
  module McpToolSet
    def self.available_for?(_repo)
      false
    end

    def self.tool_definitions
      []
    end
  end
end
