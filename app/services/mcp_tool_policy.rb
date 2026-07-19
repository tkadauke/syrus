# Centralizes tool-selection logic for both sidecars.
# McpToolPolicy.for(context) returns the full set of tool classes the agent
# may use for the given context. Sidecars intersect this set with their own
# TOOLS/DEFERRED_TOOLS arrays so tier registration stays in the sidecar.
class McpToolPolicy
  # Capabilities that workflow-surface submit tools require. Maps a symbolic
  # capability name to the set of workflow roles that hold it. Roles absent
  # from the list do not have the capability and must not call the tool.
  WORKFLOW_CAPABILITIES = {
    submit_summary:            [
      AgentRole::WORKFLOW_IMPLEMENT,
      AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
      AgentRole::WORKFLOW_REBASE_CONFLICT,
      AgentRole::WORKFLOW_MANUAL
    ].freeze,
    submit_test_plan:          [
      AgentRole::WORKFLOW_IMPLEMENT,
      AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
      AgentRole::WORKFLOW_REBASE_CONFLICT,
      AgentRole::WORKFLOW_MANUAL
    ].freeze,
    submit_adversarial_review: [
      AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER,
      AgentRole::WORKFLOW_MANUAL
    ].freeze
  }.freeze

  def self.for(context)
    new(context).allowed_tools
  end

  # Returns true when a context's role holds the named workflow capability.
  # Non-workflow roles always return false so the check is safe to call for any context.
  def self.capability_permitted?(context, capability)
    permitted_roles = WORKFLOW_CAPABILITIES.fetch(capability.to_sym, [])
    permitted_roles.include?(context.role)
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

  # Per-step workflow tool set. Submit tools are role-specific so the
  # adversarial reviewer cannot call submit_summary/submit_test_plan and
  # non-reviewer roles cannot call submit_adversarial_review.
  def workflow_tools
    base = [
      SyrusMcp::ReadLiveStateTool,
      Mcp::Tools::ReadMemoryTool,
      Mcp::Tools::WriteMemoryTool,
      Mcp::Tools::DeleteMemoryTool,
      Mcp::Tools::SearchMemoriesTool,
      Mcp::Tools::ListMemoriesTool,
      SyrusMcp::GetCoverageReportTool,
      SyrusMcp::ReportMainConcernTool
    ]

    if @context.role == AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER
      base + [ SyrusMcp::SubmitAdversarialReviewTool ]
    else
      base + [ SyrusMcp::SubmitSummaryTool, SyrusMcp::SubmitTestPlanTool ]
    end
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
