module Syrus
  module Plugin
    # Interface for plugins that want a best-effort agentic pass after an
    # implementation-style workflow has produced its final diff.
    #
    # Providers are enabled/disabled through the normal plugin registry. Core
    # contributes only one generic host step; plugin-specific storage and MCP
    # tools stay in the plugin.
    module PostImplementationReviewProvider
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def review_needed?(job:, trigger_kind:)
          true
        end

        def prompt_sections(job:, workflow:, run:)
          []
        end

        def required_mcp_tools(job:, workflow:, run:)
          []
        end
      end
    end
  end
end
