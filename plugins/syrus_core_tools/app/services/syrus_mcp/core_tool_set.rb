module SyrusMcp
  # Bundled MCP tool set that registers the built-in Syrus sidecar tools
  # with the plugin registry. This is the reference implementation of the
  # Syrus::Plugin::McpToolSet interface; external plugins follow the same
  # pattern to add tools visible to workflow agents.
  class CoreToolSet
    include Syrus::Plugin::McpToolSet

    # Every tool class the built-in workflow sidecar can offer.
    # Role-based filtering (e.g. submit_adversarial_review only for grader
    # steps) is applied by the Sidecar using McpToolPolicy, not here — this
    # list is the full unfiltered menu.
    MCP_TOOL_CLASSES = [
      ReadLiveStateTool,
      ::Mcp::Tools::ReadMemoryTool,
      ::Mcp::Tools::WriteMemoryTool,
      ::Mcp::Tools::DeleteMemoryTool,
      ::Mcp::Tools::SearchMemoriesTool,
      ::Mcp::Tools::ListMemoriesTool,
      GetCoverageReportTool,
      ReportMainConcernTool,
      SubmitSummaryTool,
      SubmitTestPlanTool,
      SubmitAdversarialReviewTool
    ].freeze

    # The set of tool names this class declares; used by the Sidecar to
    # distinguish built-in policy-managed tools from external plugin tools
    # that should bypass McpToolPolicy role filtering.
    POLICY_MANAGED_NAMES = MCP_TOOL_CLASSES.map(&:tool_name).freeze

    def self.available_for?(_repository)
      true
    end

    def self.tool_definitions
      MCP_TOOL_CLASSES.map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h
        }
      end
    end

    def handle(tool_name, params, context)
      klass = MCP_TOOL_CLASSES.find { |k| k.tool_name == tool_name }
      raise "SyrusMcp::CoreToolSet: unknown tool #{tool_name.inspect}" unless klass
      klass.call(**params, server_context: context)
    end
  end
end
