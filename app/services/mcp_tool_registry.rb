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
        chat(Mcp::Tools::AttachRepositoryTool, mutation: true),
        chat(Mcp::Tools::ProposeEpicTool, mutation: true),
        chat(Mcp::Tools::ProposeJobTool, mutation: true),
        chat(Mcp::Tools::ProposeEpicWithJobsTool, mutation: true),
        chat(Mcp::Tools::ListProposalsTool),
        chat(Mcp::Tools::DeleteProposalTool, mutation: true),
        chat(Mcp::Tools::SetBookmarkTool, mutation: true),
        chat(Mcp::Tools::ListJobsTool),
        chat(Mcp::Tools::SearchJobsTool),
        chat(Mcp::Tools::ReadJobTool),
        chat(Mcp::Tools::ListEpicsTool),
        chat(Mcp::Tools::ReadEpicTool),
        chat(Mcp::Tools::ApproveJobTool, mutation: true),
        chat(Mcp::Tools::CancelJobTool, mutation: true),
        chat(Mcp::Tools::CloseJobSuccessfullyTool, mutation: true),
        chat(Mcp::Tools::RetryJobTool, mutation: true),
        chat(Mcp::Tools::SetJobPriorityTool, mutation: true),
        chat(Mcp::Tools::WriteMemoryTool, mutation: true),
        chat(Mcp::Tools::ReadMemoryTool),
        chat(Mcp::Tools::RepoInfoTool),
        chat(Mcp::Tools::SubmitChatFeedbackTool, mutation: true),
        chat(Mcp::Tools::RenameChatTool, mutation: true),
        chat(Mcp::Tools::SuggestNextStepTool, mutation: true),
        chat(Mcp::Tools::AskUserQuestionTool, mutation: true),
        chat(Mcp::Tools::ResetWorkspaceTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        chat(Mcp::Tools::CompleteImplementStepTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        chat(Mcp::Tools::SubmitCodingChangesTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        chat(Mcp::Tools::AdminOverviewTool, admin_only: true),
        chat(Mcp::Tools::AdminStuckJobsTool, admin_only: true),
        chat(Mcp::Tools::AdminQueueDetailTool, admin_only: true),
        chat(Mcp::Tools::AdminListProcessesTool, admin_only: true),
        chat(Mcp::Tools::AdminListRunsTool, admin_only: true),
        chat(Mcp::Tools::AdminListUsersTool, admin_only: true),
        chat(Mcp::Tools::AdminVersionTool, admin_only: true),
        chat(Mcp::Tools::ReadWorkerHealthTool, admin_only: true),
        chat(Mcp::Tools::AdminReadOperationalLogsTool, admin_only: true),
        chat(Mcp::Tools::AdminKillProcessTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdminReapStaleRunsTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdminPausePollingTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdminUnpausePollingTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdminPauseRunsTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdminUnpauseRunsTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdminClearGithubCacheTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdminPauseUserSchedulingTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdminUnpauseUserSchedulingTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdminRetryStepTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdminCleanupWorkspaceTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdminRefreshInstallationsTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdminGithubAppInstallationDiagnosticTool, admin_only: true),
        chat(Mcp::Tools::ForceFailJobTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::ReconcileJobStateTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::ForceStateTransitionTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::CancelStaleWorkTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::ReenqueueWorkTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::ForceRebaseTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::RestackEpicTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::ForceLandingRecheckTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::ManualAgenticRunTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::AdoptCurrentPrHeadTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::ReplacePrBranchWithWorkflowOutputTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::RetryFromCurrentPrBranchTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::RefreshPrChecksTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::RerunCiRepairTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::MarkCiRepairNoopTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::OverrideLandingBlockerOnceTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::WakeLandingQueueTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::InspectProviderCircuitTool, admin_only: true),
        chat(Mcp::Tools::RepairProviderCircuitEvidenceTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::ClearProviderCircuitTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::WakeProviderAdmissionTool, admin_only: true, mutation: true),
        chat(Mcp::Tools::ReadFileTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]),
        chat(Mcp::Tools::WriteFileTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        chat(Mcp::Tools::ListFilesTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]),
        chat(Mcp::Tools::RunCommandTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        chat(Mcp::Tools::GitDiffTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]),
        chat(Mcp::Tools::GitStatusTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]),
        chat(Mcp::Tools::OpenInLocalModeTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        chat(Mcp::Tools::CancelLocalModeTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        chat(Mcp::Tools::CreateCodingJobTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        chat(Mcp::Tools::UpdatePinnedContextTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::RemovePinnedContextTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ListChatsTool, tier: :deferred),
        chat(Mcp::Tools::ListRepositoriesTool, tier: :deferred),
        chat(Mcp::Tools::GetJobDiffTool, tier: :deferred),
        chat(Mcp::Tools::UpdateJobTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ListJobWorkflowsTool, tier: :deferred),
        chat(Mcp::Tools::ReadWorkflowTool, tier: :deferred),
        chat(Mcp::Tools::ReadRunTranscriptTool, tier: :deferred),
        chat(Mcp::Tools::ExplainStuckJobTool, tier: :deferred),
        chat(Mcp::Tools::AssignJobToEpicTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ListOpenIssuesTool, tier: :deferred),
        chat(Mcp::Tools::ListOpenPrsTool, tier: :deferred),
        chat(Mcp::Tools::SearchChatsTool, tier: :deferred),
        chat(Mcp::Tools::ReadChatMessagesTool, tier: :deferred),
        chat(Mcp::Tools::GetSpendingTool, tier: :deferred),
        chat(Mcp::Tools::ListTagsTool, tier: :deferred),
        chat(Mcp::Tools::CreateTagTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::AddJobTagTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::RemoveJobTagTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::RebaseJobTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ReopenJobTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::PollJobFeedbackTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::RunVisualReviewTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::CheckJobMergeabilityTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::DelegateIssueTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ReadPrTool, tier: :deferred),
        chat(Mcp::Tools::UnapproveJobTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::RemoveJobFromEpicTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::StartEpicTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::MoveEpicToBacklogTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ArchiveEpicTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::UpdateEpicTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::AddEpicDependencyTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::RemoveEpicDependencyTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::AddJobDependencyTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::RemoveJobDependencyTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::SearchMemoriesTool, tier: :deferred),
        chat(Mcp::Tools::ListMemoriesTool, tier: :deferred),
        chat(Mcp::Tools::DeleteMemoryTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::PublishMemoryTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::UnpublishMemoryTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ListRepoDocumentsTool, tier: :deferred),
        chat(Mcp::Tools::ReadRepoDocumentTool, tier: :deferred),
        chat(Mcp::Tools::CreateRepoDocumentTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::DeleteRepoDocumentTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ReadSceneTool, tier: :deferred),
        chat(Mcp::Tools::DrawShapeTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::DrawTextTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::DrawLineTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::DrawArrowTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::DrawFreedrawTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::DrawFrameTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::DrawEmbedTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::DrawImageTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::MoveElementTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::DeleteElementTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ListChatMediaTool, tier: :deferred),
        chat(Mcp::Tools::SubmitArtifactTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::SaveCanvasTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ClearCanvasTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::LoadCanvasTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::UpdateSceneTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ScheduleRecurringTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ScheduleWakeupTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ListWakeupsTool, tier: :deferred),
        chat(Mcp::Tools::CancelWakeupTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ListScheduledTasksTool, tier: :deferred),
        chat(Mcp::Tools::ReadScheduledTaskTool, tier: :deferred),
        chat(Mcp::Tools::UpdateScheduledTaskTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::PauseScheduledTaskTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ResumeScheduledTaskTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::DeleteScheduledTaskTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::FireScheduledTaskNowTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::PauseLandingQueueTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ResumeLandingQueueTool, tier: :deferred, mutation: true),
        chat(Mcp::Tools::ReadQueueTool, tier: :deferred),
        chat(Mcp::Tools::SearchSyrusDocsTool, tier: :deferred),
        chat(Mcp::Tools::GetWalkthroughAnalysisTool, tier: :deferred, feature_flag: :video_walkthroughs),
        chat(Mcp::Tools::AnalyzeWalkthroughSegmentTool, tier: :deferred, feature_flag: :video_walkthroughs),
        chat(Mcp::Tools::ReadWalkthroughFrameTool, tier: :deferred, feature_flag: :video_walkthroughs),
        chat(Mcp::Tools::ListInsightsTool, tier: :deferred, feature_flag: :agent_insights),
        chat(Mcp::Tools::ReadInsightTool, tier: :deferred, feature_flag: :agent_insights)
      ]
    end

    def workflow_entries
      workflow_roles = AgentRole::WORKFLOW_ROLES
      summary_roles = [
        AgentRole::WORKFLOW_IMPLEMENT,
        AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
        AgentRole::WORKFLOW_REBASE_CONFLICT,
        AgentRole::WORKFLOW_MANUAL
      ]

      artifact_roles = [
        AgentRole::WORKFLOW_IMPLEMENT,
        AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
        AgentRole::WORKFLOW_REBASE_CONFLICT,
        AgentRole::WORKFLOW_MANUAL
      ]

      visual_artifact_roles = artifact_roles + [ AgentRole::WORKFLOW_VISUAL_REVIEWER ]

      metadata_roles = [
        AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
        AgentRole::WORKFLOW_MANUAL
      ]

      [
        workflow(Mcp::Tools::ReadLiveStateTool, required_roles: workflow_roles),
        workflow(Mcp::Tools::ReadMemoryTool, required_roles: workflow_roles),
        workflow(Mcp::Tools::WriteMemoryTool, required_roles: workflow_roles, mutation: true),
        workflow(Mcp::Tools::DeleteMemoryTool, required_roles: workflow_roles, mutation: true),
        workflow(Mcp::Tools::SearchMemoriesTool, required_roles: workflow_roles),
        workflow(Mcp::Tools::ListMemoriesTool, required_roles: workflow_roles),
        workflow(Mcp::Tools::GetCoverageReportTool, required_roles: workflow_roles),
        workflow(Mcp::Tools::ReadRunWorkerHealthTool, required_roles: workflow_roles),
        workflow(Mcp::Tools::StartPreviewTool, required_roles: workflow_roles, mutation: true),
        workflow(Mcp::Tools::StopPreviewTool, required_roles: workflow_roles, mutation: true),
        workflow(Mcp::Tools::ReadPreviewLogTool, required_roles: workflow_roles),
        workflow(Mcp::Tools::ReportMainConcernTool, required_roles: workflow_roles, mutation: true),
        workflow(Mcp::Tools::SubmitSummaryTool, capability: :submit_summary, required_roles: summary_roles, mutation: true),
        workflow(Mcp::Tools::SubmitTestPlanTool, capability: :submit_test_plan, required_roles: summary_roles, mutation: true),
        workflow(SyrusMcp::SubmitArtifactTool, capability: :submit_artifact, required_roles: artifact_roles, mutation: true),
        workflow(SyrusMcp::SubmitVisualArtifactTool, capability: :submit_visual_artifact, required_roles: visual_artifact_roles, mutation: true),
        workflow(Mcp::Tools::SubmitJobMetadataTool, capability: :submit_job_metadata, required_roles: metadata_roles, mutation: true),
        workflow(Mcp::Tools::SubmitAdversarialReviewTool, capability: :submit_adversarial_review, required_roles: [
          AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER,
          AgentRole::WORKFLOW_MANUAL
        ], mutation: true),
        workflow(Mcp::Tools::SubmitVisualReviewTool, capability: :submit_visual_review, required_roles: [
          AgentRole::WORKFLOW_VISUAL_REVIEWER,
          AgentRole::WORKFLOW_MANUAL
        ], mutation: true),
      ]
    end

    def agent_insight_entries
      [
        entry(Mcp::Tools::ReadLiveStateTool, surface: :agent_insight),
        entry(Mcp::Tools::ReadRunWorkerHealthTool, surface: :agent_insight),
        entry(Mcp::Tools::ReadMemoryTool, surface: :agent_insight),
        entry(Mcp::Tools::WriteMemoryTool, surface: :agent_insight, mutation: true),
        entry(Mcp::Tools::SearchMemoriesTool, surface: :agent_insight),
        entry(Mcp::Tools::ListMemoriesTool, surface: :agent_insight),
        entry(Mcp::Tools::SubmitInsightTool, surface: :agent_insight, feature_flag: :agent_insights, mutation: true),
        entry(Mcp::Tools::UpdateInsightTool, surface: :agent_insight, feature_flag: :agent_insights, mutation: true),
        entry(Mcp::Tools::ListInsightsTool, surface: :agent_insight, feature_flag: :agent_insights),
        entry(Mcp::Tools::ReadInsightTool, surface: :agent_insight, feature_flag: :agent_insights),
        entry(Mcp::Tools::ListRecentWorkflowsTool, surface: :agent_insight, feature_flag: :agent_insights),
        entry(Mcp::Tools::ReadInsightRunTranscriptTool, surface: :agent_insight, feature_flag: :agent_insights)
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
