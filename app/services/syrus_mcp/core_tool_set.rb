module SyrusMcp
  def self.run_from_context(server_context)
    Mcp::Tools.run_from_context(server_context)
  end

  # Built-in workflow sidecar tools. Plugin MCP tool sets are additive; these
  # core tools are required for normal Syrus workflows and are not runtime
  # disableable.
  class CoreToolSet
    # Every tool class the built-in workflow sidecar can offer.
    # Role-based filtering (e.g. submit_adversarial_review only for grader
    # steps) is applied by the Sidecar using McpToolPolicy, not here - this
    # list is the full unfiltered menu.
    MCP_TOOL_CLASSES = [
      ::Mcp::Tools::ReadLiveStateTool,
      ::Mcp::Tools::ReadMemoryTool,
      ::Mcp::Tools::WriteMemoryTool,
      ::Mcp::Tools::DeleteMemoryTool,
      ::Mcp::Tools::SearchMemoriesTool,
      ::Mcp::Tools::ListMemoriesTool,
      ::Mcp::Tools::GetCoverageReportTool,
      ::Mcp::Tools::ReadRunWorkerHealthTool,
      ::Mcp::Tools::StartPreviewTool,
      ::Mcp::Tools::StopPreviewTool,
      ::Mcp::Tools::ReadPreviewLogTool,
      ::Mcp::Tools::ReportMainConcernTool,
      ::Mcp::Tools::SubmitSummaryTool,
      ::Mcp::Tools::SubmitTestPlanTool,
      SubmitArtifactTool,
      ::Mcp::Tools::SubmitJobMetadataTool,
      ::Mcp::Tools::SubmitAdversarialReviewTool,
      ::Mcp::Tools::SubmitInsightTool,
      ::Mcp::Tools::UpdateInsightTool,
      ::Mcp::Tools::ListInsightsTool,
      ::Mcp::Tools::ReadInsightTool,
      ::Mcp::Tools::ListRecentWorkflowsTool,
      ::Mcp::Tools::ReadInsightRunTranscriptTool
    ].freeze

    # The set of tool names managed by McpToolPolicy role filtering.
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
