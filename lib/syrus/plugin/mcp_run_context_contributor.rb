module Syrus
  module Plugin
    # Adds plugin-owned authorization context to workflow MCP runs without
    # making core resolve plugin models. Providers return constructor
    # attributes understood by McpToolContext.
    module McpRunContextContributor
      def self.included(base) = base.extend(self)

      def context_attributes(run:, role:) = {}
    end
  end
end
