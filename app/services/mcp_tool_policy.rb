# Centralizes tool-selection logic for both sidecars.
# McpToolPolicy.for(context) returns the full set of tool classes the agent
# may use for the given context. Tool exposure rules live in McpToolRegistry;
# this policy remains the stable authorization facade for callers and tools.
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
    submit_review_plan:        [
      AgentRole::WORKFLOW_IMPLEMENT,
      AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
      AgentRole::WORKFLOW_REBASE_CONFLICT,
      AgentRole::WORKFLOW_MANUAL
    ].freeze,
    submit_job_metadata:       [
      AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
      AgentRole::WORKFLOW_MANUAL
    ].freeze,
    submit_artifact:           [
      AgentRole::WORKFLOW_IMPLEMENT,
      AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
      AgentRole::WORKFLOW_REBASE_CONFLICT,
      AgentRole::WORKFLOW_MANUAL
    ].freeze,
    submit_visual_artifact:    [
      AgentRole::WORKFLOW_IMPLEMENT,
      AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
      AgentRole::WORKFLOW_REBASE_CONFLICT,
      AgentRole::WORKFLOW_MANUAL,
      AgentRole::WORKFLOW_VISUAL_REVIEWER
    ].freeze,
    submit_adversarial_review: [
      AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER,
      AgentRole::WORKFLOW_MANUAL
    ].freeze,
    submit_visual_review:      [
      AgentRole::WORKFLOW_VISUAL_REVIEWER,
      AgentRole::WORKFLOW_MANUAL
    ].freeze
  }.freeze

  # Story 11 (docs/plans/delivery-tracks-and-promotion.md) delivery-track/
  # ref-movement tools are chat- *and* skill-facing — a `run_skill` step
  # agent (e.g. a "promote release" skill) can inspect/dispatch ref
  # movement the same way a chat session can. Scoped to `run_skill`
  # specifically (not every WORKFLOW_IMPLEMENT run) so an ordinary
  # `implement` step working on an unrelated Job doesn't gain unrelated
  # dispatch tools.
  REF_MOVEMENT_TOOLS = [
    Mcp::Tools::ListDeliveryTracksTool,
    Mcp::Tools::ResolveDeliveryPolicyTool,
    Mcp::Tools::SelectJobDeliveryTrackTool,
    Mcp::Tools::ListRefMovementActionsTool,
    Mcp::Tools::DispatchRefMovementActionTool,
    Mcp::Tools::ReadRefMovementStatusTool,
    Mcp::Tools::ClassifyPullRequestTool,
    Mcp::Tools::IngestPullRequestTool
  ].freeze

  SUPERVISOR_EXCLUDED_TOOLS = [
    Mcp::Tools::AttachRepositoryTool,
    Mcp::Tools::ProposeEpicTool,
    Mcp::Tools::ProposeJobTool,
    Mcp::Tools::ProposeEpicWithJobsTool,
    Mcp::Tools::ListProposalsTool,
    Mcp::Tools::DeleteProposalTool,
    Mcp::Tools::SubmitChatFeedbackTool,
    Mcp::Tools::DelegateIssueTool,
    Mcp::Tools::ListChatMediaTool,
    Mcp::Tools::ScheduleRecurringTool,
    Mcp::Tools::FireScheduledTaskNowTool
  ].freeze


  def self.for(context)
    new(context).allowed_tools
  end

  # Returns true when a context's role holds the named workflow capability.
  # Non-workflow roles always return false so the check is safe to call for any context.
  def self.capability_permitted?(context, capability)
    McpToolRegistry.capability_permitted?(context, capability)
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
  # adversarial reviewer cannot call submit_summary/submit_test_plan, the
  # visual reviewer cannot call submit_summary/submit_test_plan/submit_artifact,
  # and non-reviewer roles cannot call submit_adversarial_review/submit_visual_review.
  # ReportMainConcernTool is excluded from both reviewer roles: they only see a
  # diff (and, for visual review, a running preview) and cannot distinguish a real
  # main-branch regression from a transient infrastructure failure, so granting it
  # would produce false quorum signals.
  def workflow_tools
    base = [
      Mcp::Tools::ReadLiveStateTool,
      Mcp::Tools::ReadMemoryTool,
      Mcp::Tools::WriteMemoryTool,
      Mcp::Tools::DeleteMemoryTool,
      Mcp::Tools::SearchMemoriesTool,
      Mcp::Tools::ListMemoriesTool,
      Mcp::Tools::GetCoverageReportTool,
      Mcp::Tools::ReadRunWorkerHealthTool,
      Mcp::Tools::ListRepositoryTestInsightsTool,
      Mcp::Tools::ReadTestInsightTool,
      Mcp::Tools::ReadJobTestResultsTool,
      Mcp::Tools::ReadRunTestResultsTool,
      Mcp::Tools::CompareTestRuntimeTool,
      Mcp::Tools::StartPreviewTool,
      Mcp::Tools::StopPreviewTool,
      Mcp::Tools::ReadPreviewLogTool
    ]
    if @context.role == AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER
      base + [ Mcp::Tools::SubmitAdversarialReviewTool ]
    elsif @context.role == AgentRole::WORKFLOW_VISUAL_REVIEWER
      base + [ Mcp::Tools::SubmitVisualReviewTool, SyrusMcp::SubmitVisualArtifactTool ]
    else
      tools = base + [ Mcp::Tools::ReportMainConcernTool, Mcp::Tools::SubmitSummaryTool, Mcp::Tools::SubmitTestPlanTool, Mcp::Tools::SubmitReviewPlanTool, SyrusMcp::SubmitArtifactTool, SyrusMcp::SubmitVisualArtifactTool ]
      tools << Mcp::Tools::SubmitJobMetadataTool if @context.run&.step&.kind == "refresh_job_metadata"
      tools += REF_MOVEMENT_TOOLS if @context.run&.step&.kind == "run_skill"
      tools
    end
  end

  # Chat tool set mirrors the existing tools_for_session filtering logic,
  # now expressed through the context object instead of a raw ChatSession.
  def chat_tools
    return chat_evaluator_tools if @context.role == AgentRole::CHAT_EVALUATOR

    apply_supervisor_filter(McpToolRegistry.tools_for_context(@context, surface: :chat))
  end

  def chat_evaluator_tools
    tools = [
      Mcp::Tools::ListJobsTool,
      Mcp::Tools::SearchJobsTool,
      Mcp::Tools::ReadJobTool,
      Mcp::Tools::ListEpicsTool,
      Mcp::Tools::ReadEpicTool,
      Mcp::Tools::ListProposalsTool,
      Mcp::Tools::RepoInfoTool,
      Mcp::Tools::ListChatsTool,
      Mcp::Tools::SearchChatsTool,
      Mcp::Tools::ReadChatMessagesTool,
      Mcp::Tools::ListRepositoriesTool,
      Mcp::Tools::GetJobDiffTool,
      Mcp::Tools::ListJobWorkflowsTool,
      Mcp::Tools::ReadWorkflowTool,
      Mcp::Tools::ReadRunTranscriptTool,
      Mcp::Tools::ReadJobTestResultsTool,
      Mcp::Tools::ReadRunTestResultsTool,
      Mcp::Tools::CompareTestRuntimeTool,
      Mcp::Tools::ListOpenIssuesTool,
      Mcp::Tools::ListOpenPrsTool,
      Mcp::Tools::ReadPrTool,
      Mcp::Tools::CheckJobMergeabilityTool,
      Mcp::Tools::ListRepoDocumentsTool,
      Mcp::Tools::ReadRepoDocumentTool,
      Mcp::Tools::ListChatMediaTool,
      Mcp::Tools::ListWakeupsTool,
      Mcp::Tools::ListScheduledTasksTool,
      Mcp::Tools::ReadScheduledTaskTool,
      Mcp::Tools::ReadQueueTool,
      Mcp::Tools::SearchSyrusDocsTool,
      Mcp::Tools::ListInsightsTool,
      Mcp::Tools::ReadInsightTool,
      Mcp::Tools::ReadMemoryTool,
      Mcp::Tools::SearchMemoriesTool,
      Mcp::Tools::ListMemoriesTool,
      Mcp::Tools::SubmitScopedEventDecisionTool
    ]
    tools = apply_admin_filter(tools)
    tools = apply_agent_insights_filter(tools)
    tools = apply_walkthrough_filter(tools)
    tools
  end

  def chat_base_tools
    Mcp::Sidecar::CHAT_ESSENTIAL_TOOLS +
      Mcp::Sidecar::CHAT_DEFERRED_TOOLS
  end

  def apply_admin_filter(tools)
    return tools if @context.user.admin?

    tools.reject { |tool| Mcp::Sidecar::CHAT_ADMIN_TOOLS.include?(tool) }
  end

  def apply_agent_insights_filter(tools)
    return tools if Feature.agent_insights_enabled?

    tools.reject { |tool| insight_read_tools.include?(tool) }
  end

  def apply_walkthrough_filter(tools)
    return tools if Feature.video_walkthroughs_enabled?

    tools.reject { |tool| Mcp::Sidecar::CHAT_WALKTHROUGH_TOOLS.include?(tool) }
  end

  def apply_coding_filter(tools)
    return tools if @context.role == AgentRole::CHAT_CODING && Feature.coding_mode_enabled?

    tools.reject do |tool|
      Mcp::Sidecar::CHAT_CODING_TOOLS.include?(tool) &&
        !role_specific_tool_allowed_for_current_context?(tool)
    end
  end

  def apply_local_mode_filter(tools)
    return tools if @context.role == AgentRole::CHAT_LOCAL && Feature.local_mode_enabled?

    tools.reject do |tool|
      Mcp::Sidecar::CHAT_LOCAL_MODE_TOOLS.include?(tool) &&
        !role_specific_tool_allowed_for_current_context?(tool)
    end
  end

  def role_specific_tool_allowed_for_current_context?(tool)
    entry = McpToolRegistry.entry_for(tool)
    return false unless entry&.surface == :chat
    return false unless entry.required_roles.include?(@context.role)

    feature_flag = entry.feature_flags_by_role&.fetch(@context.role, nil) || entry.feature_flag
    return Feature.public_send("#{feature_flag}_enabled?") if feature_flag

    true
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
      Mcp::Tools::ReadLiveStateTool,
      Mcp::Tools::ReadRunWorkerHealthTool,
      Mcp::Tools::ListRepositoryTestInsightsTool,
      Mcp::Tools::ReadTestInsightTool,
      Mcp::Tools::ReadJobTestResultsTool,
      Mcp::Tools::ReadRunTestResultsTool,
      Mcp::Tools::CompareTestRuntimeTool,
      Mcp::Tools::ReadMemoryTool,
      Mcp::Tools::WriteMemoryTool,
      Mcp::Tools::SearchMemoriesTool,
      Mcp::Tools::ListMemoriesTool
    ]
    if Feature.agent_insights_enabled?
      tools << Mcp::Tools::SubmitInsightTool
      tools << Mcp::Tools::UpdateInsightTool
      tools << Mcp::Tools::RetireInsightTool
      tools << Mcp::Tools::ListInsightsTool
      tools << Mcp::Tools::ReadInsightTool
      tools << Mcp::Tools::ListRecentWorkflowsTool
      tools << Mcp::Tools::ReadInsightRunTranscriptTool
    end
    tools
  end

  def insight_read_tools
    [
      Mcp::Tools::ListInsightsTool,
      Mcp::Tools::ReadInsightTool,
      Mcp::Tools::UpdateInsightTool
    ]
  end
end
