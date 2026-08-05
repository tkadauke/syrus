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
      AgentRole::WORKFLOW_MANUAL,
      AgentRole::WORKFLOW_RECONCILIATION_FEEDBACK
    ].freeze,
    submit_test_plan:          [
      AgentRole::WORKFLOW_IMPLEMENT,
      AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
      AgentRole::WORKFLOW_REBASE_CONFLICT,
      AgentRole::WORKFLOW_MANUAL,
      AgentRole::WORKFLOW_RECONCILIATION_FEEDBACK
    ].freeze,
    submit_job_metadata:       [
      AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
      AgentRole::WORKFLOW_MANUAL
    ].freeze,
    submit_adversarial_review: [
      AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER,
      AgentRole::WORKFLOW_MANUAL
    ].freeze,
    submit_chat_feedback: [
      AgentRole::WORKFLOW_RECONCILIATION_FEEDBACK,
      AgentRole::WORKFLOW_MANUAL
    ].freeze
  }.freeze

  SUPERVISOR_EXCLUDED_TOOLS = [
    SyrusChatMcp::AttachRepositoryTool,
    SyrusChatMcp::ProposeEpicTool,
    SyrusChatMcp::ProposeJobTool,
    SyrusChatMcp::ProposeEpicWithJobsTool,
    SyrusChatMcp::ListProposalsTool,
    SyrusChatMcp::DeleteProposalTool,
    SyrusChatMcp::SubmitChatFeedbackTool,
    SyrusChatMcp::DelegateIssueTool,
    SyrusChatMcp::ListChatMediaTool,
    SyrusChatMcp::ScheduleRecurringTool,
    SyrusChatMcp::FireScheduledTaskNowTool
  ].freeze

  def self.for(context)
    new(context).allowed_tools
  end

  # Returns true when a context's role holds the named workflow capability.
  # Non-workflow roles always return false so the check is safe to call for any context.
  def self.capability_permitted?(context, capability)
    permitted_roles = WORKFLOW_CAPABILITIES.fetch(capability.to_sym, [])
    permitted_roles.include?(context.role)
  end

  def self.syrus_repository?(repository)
    return false unless repository

    repository.slug.casecmp?("tkadauke/syrus") ||
      repository.upstream_slug.to_s.casecmp?("tkadauke/syrus")
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
    when AgentRole::AGENT_INSIGHT
      insight_tools
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
  # ReportMainConcernTool is excluded from the adversarial reviewer: it only
  # sees a diff and cannot distinguish a real main-branch regression from a
  # transient infrastructure failure, so granting it would produce false quorum signals.
  def workflow_tools
    base = [
      SyrusMcp::ReadLiveStateTool,
      Mcp::Tools::ReadMemoryTool,
      Mcp::Tools::WriteMemoryTool,
      Mcp::Tools::DeleteMemoryTool,
      Mcp::Tools::SearchMemoriesTool,
      Mcp::Tools::ListMemoriesTool,
      SyrusMcp::GetCoverageReportTool,
      SyrusMcp::ReadRunWorkerHealthTool
    ]
    if @context.role == AgentRole::WORKFLOW_IMPLEMENT && self.class.syrus_repository?(@context.repository)
      base << SyrusMcp::ReadPerformanceDiagnosticsTool
      base << SyrusMcp::ReadSyrusLogsTool
    end

    if @context.role == AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER
      base + [ SyrusMcp::SubmitAdversarialReviewTool ]
    elsif @context.role == AgentRole::WORKFLOW_RECONCILIATION_FEEDBACK
      base + [ SyrusMcp::ReportMainConcernTool, SyrusMcp::SubmitSummaryTool, SyrusMcp::SubmitTestPlanTool, SyrusMcp::SubmitReconciliationFeedbackTool ]
    else
      tools = base + [ SyrusMcp::ReportMainConcernTool, SyrusMcp::SubmitSummaryTool, SyrusMcp::SubmitTestPlanTool ]
      tools << SyrusMcp::SubmitJobMetadataTool if @context.run&.step&.kind == "refresh_job_metadata"
      tools
    end
  end

  # Chat tool set mirrors the existing tools_for_session filtering logic,
  # now expressed through the context object instead of a raw ChatSession.
  def chat_tools
    return chat_evaluator_tools if @context.role == AgentRole::CHAT_EVALUATOR

    tools = chat_base_tools
    tools = apply_admin_filter(tools)
    tools = apply_agent_insights_filter(tools)
    tools = apply_walkthrough_filter(tools)
    tools = apply_coding_filter(tools)
    tools = apply_local_mode_filter(tools)
    tools = apply_supervisor_filter(tools)
    tools
  end

  def chat_evaluator_tools
    tools = [
      SyrusChatMcp::ListJobsTool,
      SyrusChatMcp::SearchJobsTool,
      SyrusChatMcp::ReadJobTool,
      SyrusChatMcp::ListEpicsTool,
      SyrusChatMcp::ReadEpicTool,
      SyrusChatMcp::ListProposalsTool,
      SyrusChatMcp::RepoInfoTool,
      SyrusChatMcp::ListChatsTool,
      SyrusChatMcp::SearchChatsTool,
      SyrusChatMcp::ReadChatMessagesTool,
      SyrusChatMcp::ListRepositoriesTool,
      SyrusChatMcp::GetJobDiffTool,
      SyrusChatMcp::ListJobWorkflowsTool,
      SyrusChatMcp::ReadWorkflowTool,
      SyrusChatMcp::ReadRunTranscriptTool,
      SyrusChatMcp::ListOpenIssuesTool,
      SyrusChatMcp::ListOpenPrsTool,
      SyrusChatMcp::ReadPrTool,
      SyrusChatMcp::CheckJobMergeabilityTool,
      SyrusChatMcp::ListRepoDocumentsTool,
      SyrusChatMcp::ReadRepoDocumentTool,
      SyrusChatMcp::ListChatMediaTool,
      SyrusChatMcp::ReadSceneTool,
      SyrusChatMcp::ListWakeupsTool,
      SyrusChatMcp::ListScheduledTasksTool,
      SyrusChatMcp::ReadScheduledTaskTool,
      SyrusChatMcp::ReadQueueTool,
      SyrusChatMcp::SearchSyrusDocsTool,
      SyrusMcp::ListInsightsTool,
      SyrusMcp::ReadInsightTool,
      Mcp::Tools::ReadMemoryTool,
      Mcp::Tools::SearchMemoriesTool,
      Mcp::Tools::ListMemoriesTool
    ]
    tools = apply_admin_filter(tools)
    tools = apply_agent_insights_filter(tools)
    tools = apply_walkthrough_filter(tools)
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

  def apply_agent_insights_filter(tools)
    return tools if Feature.agent_insights_enabled?

    tools.reject { |tool| insight_read_tools.include?(tool) }
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

  def apply_supervisor_filter(tools)
    return tools unless @context.chat_session&.system_kind_supervisor?

    tools.reject { |tool| SUPERVISOR_EXCLUDED_TOOLS.include?(tool) }
  end

  # Insight agents: read-live-state + memory tools + submit_insight (when
  # the feature flag is on). No submit_summary / submit_test_plan /
  # submit_adversarial_review — insight jobs never open PRs.
  def insight_tools
    tools = [
      SyrusMcp::ReadLiveStateTool,
      SyrusMcp::ReadRunWorkerHealthTool,
      Mcp::Tools::ReadMemoryTool,
      Mcp::Tools::WriteMemoryTool,
      Mcp::Tools::SearchMemoriesTool,
      Mcp::Tools::ListMemoriesTool
    ]
    if Feature.agent_insights_enabled?
      tools << SyrusMcp::SubmitInsightTool
      tools << SyrusMcp::UpdateInsightTool
      tools << SyrusMcp::ListInsightsTool
      tools << SyrusMcp::ReadInsightTool
      tools << SyrusMcp::ListRecentWorkflowsTool
      tools << SyrusMcp::ReadInsightRunTranscriptTool
    end
    tools << SyrusMcp::ReadSyrusLogsTool if insight_operational_log_search_available?
    tools
  end

  def insight_operational_log_search_available?
    Feature.operational_log_indexing_enabled? && self.class.syrus_repository?(@context.repository)
  end

  def insight_read_tools
    [
      SyrusMcp::ListInsightsTool,
      SyrusMcp::ReadInsightTool,
      SyrusMcp::UpdateInsightTool
    ]
  end
end
