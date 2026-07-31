class McpToolRegistry
  Entry = Data.define(
    :tool,
    :surface,
    :tier,
    :admin_only,
    :feature_flag,
    :required_roles,
    :capability,
    :mutation
  ) do
    def tool_name
      tool.name.demodulize.sub(/Tool\z/, "").underscore
    end

    def read_only?
      !mutation
    end

    def to_h
      {
        tool_name: tool_name,
        tool: tool,
        surface: surface,
        tier: tier,
        admin_only: admin_only,
        feature_flag: feature_flag,
        required_roles: required_roles,
        capability: capability,
        mutation: mutation,
        read_only: read_only?
      }
    end
  end

  class << self
    def entries
      @entries ||= build_entries.freeze
    end

    def tools(surface: nil, tier: nil)
      matching_entries(surface: surface, tier: tier).map(&:tool)
    end

    def entries_for_context(context, surface: nil, tier: nil)
      matching_entries(surface: surface, tier: tier).select { |entry| allowed_entry?(entry, context) }
    end

    def tools_for_context(context, surface: nil, tier: nil)
      entries_for_context(context, surface: surface, tier: tier).map(&:tool)
    end

    def summaries(surface: nil, tier: nil)
      matching_entries(surface: surface, tier: tier).map(&:to_h)
    end

    def entry_for(tool)
      entries.find { |entry| entry.tool == tool }
    end

    def capability_permitted?(context, capability)
      entries.any? do |entry|
        entry.capability == capability.to_sym &&
          allowed_entry?(entry, context)
      end
    end

    private

    def matching_entries(surface:, tier:)
      entries.select do |entry|
        (surface.nil? || entry.surface == surface.to_sym) &&
          (tier.nil? || entry.tier == tier.to_sym)
      end
    end

    def allowed_entry?(entry, context)
      return false unless surface_allowed?(entry, context)
      return false if entry.admin_only && !context.user.admin?
      return false if entry.feature_flag && !Feature.public_send("#{entry.feature_flag}_enabled?")
      return false if entry.required_roles.any? && !entry.required_roles.include?(context.role)

      true
    end

    def surface_allowed?(entry, context)
      if context.chat?
        entry.surface == :chat && AgentRole::CHAT_ROLES.include?(context.role)
      elsif context.run?
        entry.surface == :workflow && AgentRole::WORKFLOW_ROLES.include?(context.role) ||
          entry.surface == :agent_insight && context.role == AgentRole::AGENT_INSIGHT
      else
        false
      end
    end

    def build_entries
      [
        *chat_entries,
        *workflow_entries,
        *agent_insight_entries
      ]
    end

    def chat_entries
      [
        chat(SyrusChatMcp::AttachRepositoryTool, mutation: true),
        chat(SyrusChatMcp::ProposeEpicTool, mutation: true),
        chat(SyrusChatMcp::ProposeJobTool, mutation: true),
        chat(SyrusChatMcp::ProposeEpicWithJobsTool, mutation: true),
        chat(SyrusChatMcp::ListProposalsTool),
        chat(SyrusChatMcp::DeleteProposalTool, mutation: true),
        chat(SyrusChatMcp::SetBookmarkTool, mutation: true),
        chat(SyrusChatMcp::ListJobsTool),
        chat(SyrusChatMcp::SearchJobsTool),
        chat(SyrusChatMcp::ReadJobTool),
        chat(SyrusChatMcp::ListEpicsTool),
        chat(SyrusChatMcp::ReadEpicTool),
        chat(SyrusChatMcp::ApproveJobTool, mutation: true),
        chat(SyrusChatMcp::CancelJobTool, mutation: true),
        chat(SyrusChatMcp::CloseJobSuccessfullyTool, mutation: true),
        chat(SyrusChatMcp::RetryJobTool, mutation: true),
        chat(SyrusChatMcp::SetJobPriorityTool, mutation: true),
        chat(Mcp::Tools::WriteMemoryTool, mutation: true),
        chat(Mcp::Tools::ReadMemoryTool),
        chat(SyrusChatMcp::RepoInfoTool),
        chat(SyrusChatMcp::SubmitChatFeedbackTool, mutation: true),
        chat(SyrusChatMcp::RenameChatTool, mutation: true),
        chat(SyrusChatMcp::SuggestNextStepTool, mutation: true),
        chat(SyrusChatMcp::AskUserQuestionTool, mutation: true),
        chat(SyrusChatMcp::CompleteImplementStepTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        chat(SyrusChatMcp::SubmitCodingChangesTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        chat(SyrusChatMcp::AdminOverviewTool, admin_only: true),
        chat(SyrusChatMcp::AdminStuckJobsTool, admin_only: true),
        chat(SyrusChatMcp::AdminQueueDetailTool, admin_only: true),
        chat(SyrusChatMcp::AdminListProcessesTool, admin_only: true),
        chat(SyrusChatMcp::AdminListRunsTool, admin_only: true),
        chat(SyrusChatMcp::AdminListUsersTool, admin_only: true),
        chat(SyrusChatMcp::AdminVersionTool, admin_only: true),
        chat(SyrusChatMcp::ReadWorkerHealthTool, admin_only: true),
        chat(SyrusChatMcp::AdminKillProcessTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::AdminReapStaleRunsTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::AdminPausePollingTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::AdminUnpausePollingTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::AdminPauseRunsTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::AdminUnpauseRunsTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::AdminClearGithubCacheTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::AdminPauseUserSchedulingTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::AdminUnpauseUserSchedulingTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::AdminRetryStepTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::AdminCleanupWorkspaceTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::AdminRefreshInstallationsTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::ForceFailJobTool, admin_only: true, mutation: true),
        chat(SyrusChatMcp::ReadFileTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]),
        chat(SyrusChatMcp::WriteFileTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        chat(SyrusChatMcp::ListFilesTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]),
        chat(SyrusChatMcp::RunCommandTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        chat(SyrusChatMcp::GitDiffTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]),
        chat(SyrusChatMcp::GitStatusTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]),
        chat(SyrusChatMcp::OpenInLocalModeTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        chat(SyrusChatMcp::CancelLocalModeTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        chat(SyrusChatMcp::CreateCodingJobTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        chat(SyrusChatMcp::UpdatePinnedContextTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::RemovePinnedContextTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ListChatsTool, tier: :deferred),
        chat(SyrusChatMcp::ListRepositoriesTool, tier: :deferred),
        chat(SyrusChatMcp::GetJobDiffTool, tier: :deferred),
        chat(SyrusChatMcp::UpdateJobTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ListJobWorkflowsTool, tier: :deferred),
        chat(SyrusChatMcp::ReadWorkflowTool, tier: :deferred),
        chat(SyrusChatMcp::ReadRunTranscriptTool, tier: :deferred),
        chat(SyrusChatMcp::ExplainStuckJobTool, tier: :deferred),
        chat(SyrusChatMcp::AssignJobToEpicTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ListOpenIssuesTool, tier: :deferred),
        chat(SyrusChatMcp::ListOpenPrsTool, tier: :deferred),
        chat(SyrusChatMcp::SearchChatsTool, tier: :deferred),
        chat(SyrusChatMcp::ReadChatMessagesTool, tier: :deferred),
        chat(SyrusChatMcp::GetSpendingTool, tier: :deferred),
        chat(SyrusChatMcp::ListTagsTool, tier: :deferred),
        chat(SyrusChatMcp::CreateTagTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::AddJobTagTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::RemoveJobTagTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::RebaseJobTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ReopenJobTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::PollJobFeedbackTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::CheckJobMergeabilityTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::DelegateIssueTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ReadPrTool, tier: :deferred),
        chat(SyrusChatMcp::UnapproveJobTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::RemoveJobFromEpicTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::StartEpicTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::MoveEpicToBacklogTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ArchiveEpicTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::UpdateEpicTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::AddEpicDependencyTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::RemoveEpicDependencyTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::AddJobDependencyTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::RemoveJobDependencyTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::SearchMemoriesTool, tier: :deferred),
        chat(Mcp::Tools::ListMemoriesTool, tier: :deferred),
        chat(Mcp::Tools::DeleteMemoryTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::PublishMemoryTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::UnpublishMemoryTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ListRepoDocumentsTool, tier: :deferred),
        chat(SyrusChatMcp::ReadRepoDocumentTool, tier: :deferred),
        chat(SyrusChatMcp::CreateRepoDocumentTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::DeleteRepoDocumentTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ReadSceneTool, tier: :deferred),
        chat(SyrusChatMcp::DrawShapeTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::DrawTextTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::DrawLineTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::DrawArrowTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::DrawFreedrawTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::DrawFrameTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::DrawEmbedTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::DrawImageTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::MoveElementTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::DeleteElementTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ListChatMediaTool, tier: :deferred),
        chat(SyrusChatMcp::SaveCanvasTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ClearCanvasTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::LoadCanvasTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::UpdateSceneTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ScheduleRecurringTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ScheduleWakeupTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ListWakeupsTool, tier: :deferred),
        chat(SyrusChatMcp::CancelWakeupTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ListScheduledTasksTool, tier: :deferred),
        chat(SyrusChatMcp::ReadScheduledTaskTool, tier: :deferred),
        chat(SyrusChatMcp::UpdateScheduledTaskTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::PauseScheduledTaskTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ResumeScheduledTaskTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::DeleteScheduledTaskTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::FireScheduledTaskNowTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::PauseLandingQueueTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ResumeLandingQueueTool, tier: :deferred, mutation: true),
        chat(SyrusChatMcp::ReadQueueTool, tier: :deferred),
        chat(SyrusChatMcp::SearchSyrusDocsTool, tier: :deferred),
        chat(SyrusChatMcp::GetWalkthroughAnalysisTool, tier: :deferred, feature_flag: :video_walkthroughs),
        chat(SyrusChatMcp::AnalyzeWalkthroughSegmentTool, tier: :deferred, feature_flag: :video_walkthroughs),
        chat(SyrusChatMcp::ReadWalkthroughFrameTool, tier: :deferred, feature_flag: :video_walkthroughs)
      ]
    end

    def workflow_entries
      workflow_roles = AgentRole::WORKFLOW_ROLES
      summary_roles = [
        AgentRole::WORKFLOW_IMPLEMENT,
        AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
        AgentRole::WORKFLOW_REBASE_CONFLICT,
        AgentRole::WORKFLOW_MANUAL,
        AgentRole::WORKFLOW_RECONCILIATION_FEEDBACK
      ]

      [
        workflow(SyrusMcp::ReadLiveStateTool, required_roles: workflow_roles),
        workflow(Mcp::Tools::ReadMemoryTool, required_roles: workflow_roles),
        workflow(Mcp::Tools::WriteMemoryTool, required_roles: workflow_roles, mutation: true),
        workflow(Mcp::Tools::DeleteMemoryTool, required_roles: workflow_roles, mutation: true),
        workflow(Mcp::Tools::SearchMemoriesTool, required_roles: workflow_roles),
        workflow(Mcp::Tools::ListMemoriesTool, required_roles: workflow_roles),
        workflow(SyrusMcp::GetCoverageReportTool, required_roles: workflow_roles),
        workflow(SyrusMcp::ReadRunWorkerHealthTool, required_roles: workflow_roles),
        workflow(SyrusMcp::ReportMainConcernTool, required_roles: workflow_roles, mutation: true),
        workflow(SyrusMcp::SubmitSummaryTool, capability: :submit_summary, required_roles: summary_roles, mutation: true),
        workflow(SyrusMcp::SubmitTestPlanTool, capability: :submit_test_plan, required_roles: summary_roles, mutation: true),
        workflow(SyrusMcp::SubmitAdversarialReviewTool, capability: :submit_adversarial_review, required_roles: [
          AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER,
          AgentRole::WORKFLOW_MANUAL
        ], mutation: true),
        workflow(SyrusMcp::SubmitReconciliationFeedbackTool, capability: :submit_chat_feedback, required_roles: [
          AgentRole::WORKFLOW_RECONCILIATION_FEEDBACK,
          AgentRole::WORKFLOW_MANUAL
        ], mutation: true)
      ]
    end

    def agent_insight_entries
      [
        entry(SyrusMcp::ReadLiveStateTool, surface: :agent_insight),
        entry(SyrusMcp::ReadRunWorkerHealthTool, surface: :agent_insight),
        entry(Mcp::Tools::ReadMemoryTool, surface: :agent_insight),
        entry(Mcp::Tools::WriteMemoryTool, surface: :agent_insight, mutation: true),
        entry(Mcp::Tools::SearchMemoriesTool, surface: :agent_insight),
        entry(Mcp::Tools::ListMemoriesTool, surface: :agent_insight),
        entry(SyrusMcp::SubmitInsightTool, surface: :agent_insight, feature_flag: :agent_insights, mutation: true),
        entry(SyrusMcp::ListInsightsTool, surface: :agent_insight, feature_flag: :agent_insights),
        entry(SyrusMcp::ReadInsightTool, surface: :agent_insight, feature_flag: :agent_insights)
      ]
    end

    def chat(tool, tier: :essential, **metadata)
      entry(tool, surface: :chat, tier: tier, **metadata)
    end

    def workflow(tool, **metadata)
      entry(tool, surface: :workflow, **metadata)
    end

    def entry(tool, surface:, tier: nil, admin_only: false, feature_flag: nil,
              required_roles: [], capability: nil, mutation: false)
      Entry.new(
        tool: tool,
        surface: surface.to_sym,
        tier: tier&.to_sym,
        admin_only: admin_only,
        feature_flag: feature_flag&.to_sym,
        required_roles: Array(required_roles).freeze,
        capability: capability&.to_sym,
        mutation: mutation
      )
    end
  end
end
