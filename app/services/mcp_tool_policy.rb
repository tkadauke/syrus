# Centralizes tool-selection logic for both sidecars.
# McpToolPolicy.for(context) returns the full set of tool classes the agent
# may use for the given context. Sidecars intersect this set with their own
# TOOLS/DEFERRED_TOOLS arrays so tier registration stays in the sidecar.
class McpToolPolicy
  def self.for(context)
    new(context).allowed_tools
  end

  def initialize(context)
    @context = context
  end

  def allowed_tools
    case @context.role
    when *AgentRole::WORKFLOW_ROLES
      workflow_tools
    when *AgentRole::CHAT_ROLES
      chat_tools
    when *AgentRole::HELPER_ROLES
      []
    else
      []
    end
  end

  private

  # All workflow run tools (behavior-preserving: same set as today's hardcoded list).
  def workflow_tools
    [
      SyrusMcp::ReadLiveStateTool,
      Mcp::Tools::ReadMemoryTool,
      Mcp::Tools::WriteMemoryTool,
      Mcp::Tools::DeleteMemoryTool,
      Mcp::Tools::SearchMemoriesTool,
      Mcp::Tools::ListMemoriesTool,
      SyrusMcp::GetCoverageReportTool,
      SyrusMcp::SubmitSummaryTool,
      SyrusMcp::SubmitTestPlanTool,
      SyrusMcp::SubmitAdversarialReviewTool,
      SyrusMcp::ReportMainConcernTool
    ]
  end

  # Chat tool set mirrors the existing tools_for_session filtering logic,
  # now expressed through the context object instead of a raw ChatSession.
  def chat_tools
    tools = chat_base_tools
    tools = apply_admin_filter(tools)
    tools = apply_walkthrough_filter(tools)
    tools = apply_coding_filter(tools)
    tools = apply_local_mode_filter(tools)
    tools
  end

  def chat_base_tools
    SyrusChatMcp::Sidecar::TOOLS +
      SyrusChatMcp::DeferredSidecar::DEFERRED_TOOLS
  end

  def apply_admin_filter(tools)
    return tools if @context.user.admin?

    tools.reject { |tool| SyrusChatMcp::Sidecar::ADMIN_TOOLS.include?(tool) }
  end

  def apply_walkthrough_filter(tools)
    return tools if Feature.video_walkthroughs_enabled?

    tools.reject { |tool| SyrusChatMcp::Sidecar::WALKTHROUGH_TOOLS.include?(tool) }
  end

  def apply_coding_filter(tools)
    return tools if @context.role == AgentRole::CHAT_CODING && Feature.coding_mode_enabled?

    tools.reject { |tool| SyrusChatMcp::Sidecar::CODING_TOOLS.include?(tool) }
  end

  def apply_local_mode_filter(tools)
    return tools if @context.role == AgentRole::CHAT_LOCAL && Feature.local_mode_enabled?

    tools.reject { |tool| SyrusChatMcp::Sidecar::LOCAL_MODE_TOOLS.include?(tool) }
  end
end
