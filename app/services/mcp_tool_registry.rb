class McpToolRegistry
  Entry = Data.define(
    :tool,
    :surface,
    :tier,
    :admin_only,
    :feature_flag,
    :feature_flags_by_role,
    :required_roles,
    :step_kinds,
    :capability,
    :interactive_only,
    :mutation,
    :ungated,
    :descriptor,
    :explicit_descriptor,
    :compatibility_descriptor
  ) do
    def tool_name
      McpToolRegistry.tool_name_for(tool)
    end

    def read_only?
      !mutation
    end

    def compatibility_descriptor? = compatibility_descriptor

    def to_h
      {
        tool_name: tool_name,
        tool: tool,
        surface: surface,
        tier: tier,
        admin_only: admin_only,
        feature_flag: feature_flag,
        feature_flags_by_role: feature_flags_by_role,
        required_roles: required_roles,
        step_kinds: step_kinds,
        capability: capability,
        interactive_only: interactive_only,
        mutation: mutation,
        ungated: ungated,
        descriptor: descriptor,
        explicit_descriptor: explicit_descriptor,
        compatibility_descriptor: compatibility_descriptor,
        read_only: read_only?
      }
    end
  end

  class << self
    SURFACE_ENTRY_BUILDERS = {
      chat: :chat_entries,
      coworker: :coworker_entries,
      workflow: :workflow_entries,
      agent_insight: :agent_insight_entries
    }.freeze

    def entries(surface: nil)
      return all_entries if surface.nil?

      entries_for_surface(surface.to_sym)
    end

    def tools(surface: nil, tier: nil)
      matching_entries(surface: surface, tier: tier).map(&:tool)
    end

    def entries_for_context(context, surface: nil, tier: nil)
      candidates = matching_entries(surface: surface, tier: tier)
      allowed = candidates.select { |entry| allowed_entry?(entry, context) }
      begin
        Permissions::ShadowEvaluator.compare(entries: candidates, context:, current_entries: allowed)
      rescue StandardError => error
        Rails.logger.warn("[McpToolRegistry] permission shadow evaluation failed: #{error.class}: #{error.message}")
      end
      allowed
    end

    def tools_for_context(context, surface: nil, tier: nil)
      entries_for_context(context, surface: surface, tier: tier).map(&:tool)
    end

    def summaries(surface: nil, tier: nil)
      matching_entries(surface: surface, tier: tier).map(&:to_h)
    end

    def coworker_grants
      [
        {
          name: "code.read",
          label: "Read repository code",
          description: "Attach read-only repository checkouts and browse source, pull requests, and Job diffs within the selected repositories.",
          default_policy: "auto",
          maximum_policy: "auto",
          tools: entries(surface: :coworker).select { |entry| entry.capability == :"code.read" }.map(&:tool_name),
          scope_options_callback: ->(user:) { Mcp::Tools::CoworkerRepositoryAccess.scope_options(user:) },
          scope_label_callback: ->(value) { Mcp::Tools::CoworkerRepositoryAccess.scope_label(value) },
          valid_scope_callback: ->(value, user:) { Mcp::Tools::CoworkerRepositoryAccess.valid_scope?(value, user:) }
        },
        {
          name: "ops.read_logs",
          label: "Read operational observability",
          description: "Read redacted operational logs, worker and queue diagnostics, admission evidence, exception events, browser errors, and performance traces.",
          default_policy: "confirm",
          maximum_policy: "auto",
          tools: entries(surface: :coworker).select { |entry| entry.capability == :"ops.read_logs" }.map(&:tool_name),
          scope_options_callback: nil,
          scope_label_callback: nil,
          valid_scope_callback: nil
        }
      ]
    end

    def entry_for(tool)
      entries.find { |entry| entry.tool == tool }
    end

    def tool_name_for(tool)
      raw = if tool.respond_to?(:tool_name) && tool.tool_name.present?
        tool.tool_name
      elsif tool.respond_to?(:name) && tool.name.present? && tool.name != "Class"
        tool.name
      elsif tool.class.name.present?
        tool.class.name
      else
        tool.to_s
      end

      raw.to_s.demodulize.sub(/Tool\z/, "").underscore.presence || "unknown"
    end

    def capability_permitted?(context, capability)
      surfaces_for_context(context).any? do |surface|
        entries(surface: surface).any? do |entry|
          entry.capability == capability.to_sym &&
            allowed_entry?(entry, context)
        end
      end
    end

    def tool_permitted?(context, tool)
      surfaces_for_context(context).any? do |surface|
        entries(surface: surface).any? do |entry|
          entry.tool == tool && allowed_entry?(entry, context)
        end
      end
    end

    private

    def all_entries
      @entries ||= SURFACE_ENTRY_BUILDERS.keys.flat_map { |surface| entries_for_surface(surface) }.freeze
    end

    def entries_for_surface(surface)
      builder = SURFACE_ENTRY_BUILDERS.fetch(surface)
      (@entries_by_surface ||= {})[surface] ||= send(builder).freeze
    end

    def surfaces_for_context(context)
      return [ :coworker ] if context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
      return [ :chat ] if context.chat?
      return [ :workflow, :agent_insight ] if context.run?

      []
    end

    def matching_entries(surface:, tier:)
      entries(surface: surface).select do |entry|
        (surface.nil? || entry.surface == surface.to_sym) &&
          (tier.nil? || entry.tier == tier.to_sym)
      end
    end

    def allowed_entry?(entry, context)
      return false unless surface_allowed?(entry, context)
      return false if entry.admin_only && !context.user.admin?
      return false if entry.interactive_only && !context.interactive
      return false unless feature_allowed?(entry, context)
      return false if entry.required_roles.any? && !entry.required_roles.include?(context.role)
      return false if entry.step_kinds.any? && !entry.step_kinds.include?(context.run&.step&.kind.to_s)

      true
    end

    def feature_allowed?(entry, context)
      role_feature_flag = entry.feature_flags_by_role&.fetch(context.role, nil)
      return Feature.public_send("#{role_feature_flag}_enabled?") if role_feature_flag
      return Feature.public_send("#{entry.feature_flag}_enabled?") if entry.feature_flag

      true
    end

    def surface_allowed?(entry, context)
      if context.chat?
        entry.surface == :chat && AgentRole::CHAT_ROLES.include?(context.role) ||
          entry.surface == :coworker && context.role == AgentRole::COWORKER_CHAT
      elsif context.run?
        entry.surface == :workflow && AgentRole::WORKFLOW_ROLES.include?(context.role) ||
          entry.surface == :agent_insight && context.role == AgentRole::AGENT_INSIGHT ||
          entry.surface == :coworker && context.role == AgentRole::COWORKER
      else
        false
      end
    end

    def chat_entries
      [
        legacy_chat(Mcp::Tools::AttachRepositoryTool, mutation: true),
        legacy_chat(Mcp::Tools::DetachRepositoryTool, mutation: true),
        legacy_chat(Mcp::Tools::ProposeEpicTool, mutation: true),
        legacy_chat(Mcp::Tools::ProposeJobTool, mutation: true),
        legacy_chat(Mcp::Tools::ProposeEpicWithJobsTool, mutation: true),
        legacy_chat(Mcp::Tools::ListProposalsTool),
        legacy_chat(Mcp::Tools::DeleteProposalTool, mutation: true),
        legacy_chat(Mcp::Tools::WithdrawPendingActionTool, mutation: true),
        permission_management_chat(Mcp::Tools::ListPermissionsTool),
        permission_management_chat(Mcp::Tools::ExplainPermissionTool),
        permission_management_chat(Mcp::Tools::GrantPermissionTool, mutation: true),
        permission_management_chat(Mcp::Tools::DenyPermissionTool, mutation: true),
        permission_management_chat(Mcp::Tools::RevokePermissionTool, mutation: true),
        permission_management_chat(Mcp::Tools::CreatePermissionLeaseTool, mutation: true),
        permission_management_chat(Mcp::Tools::RevokePermissionLeaseTool, mutation: true),
        permission_management_chat(Mcp::Tools::ApplyPermissionPresetTool, mutation: true),
        permission_management_chat(Mcp::Tools::CancelAuthorizationRequestTool, mutation: true),
        legacy_chat(Mcp::Tools::SetBookmarkTool, mutation: true),
        legacy_chat(Mcp::Tools::ListJobsTool),
        legacy_chat(Mcp::Tools::SearchJobsTool),
        legacy_chat(Mcp::Tools::ReadJobTool),
        legacy_chat(Mcp::Tools::OverrideJobPlannedExecutionTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ReadProviderRoutingRulesTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ExplainProviderRoutingTool, tier: :deferred),
        legacy_chat(Mcp::Tools::MutateProviderRoutingRulesTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ListEpicsTool),
        legacy_chat(Mcp::Tools::ReadEpicTool),
        legacy_chat(Mcp::Tools::ApproveJobTool, mutation: true),
        legacy_chat(Mcp::Tools::CancelJobTool, mutation: true),
        legacy_chat(Mcp::Tools::UnlandJobTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::UnlandEpicTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::CloseJobSuccessfullyTool, mutation: true),
        legacy_chat(Mcp::Tools::RetryJobTool, mutation: true),
        legacy_chat(Mcp::Tools::BaseRefreshRetryJobTool, mutation: true),
        legacy_chat(Mcp::Tools::SetJobPriorityTool, mutation: true),
        legacy_chat(Mcp::Tools::RepoInfoTool),
        legacy_chat(Mcp::Tools::SubmitChatFeedbackTool, mutation: true),
        legacy_chat(Mcp::Tools::RenameChatTool, mutation: true),
        legacy_chat(Mcp::Tools::PinChatTool, mutation: true),
        legacy_chat(Mcp::Tools::UnpinChatTool, mutation: true),
        legacy_chat(Mcp::Tools::SuggestNextStepTool, mutation: true),
        legacy_chat(Mcp::Tools::AskUserQuestionTool, mutation: true),
        legacy_chat(Mcp::Tools::MarkGoalCompletedTool, mutation: true),
        legacy_chat(Mcp::Tools::MarkGoalBlockedTool, mutation: true),
        legacy_chat(Mcp::Tools::ResetWorkspaceTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::CancelCodingCheckoutTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::CompleteImplementStepTool,
          feature_flags_by_role: {
            AgentRole::CHAT_CODING => :coding_mode,
            AgentRole::CHAT_LOCAL => :local_mode
          },
          required_roles: [ AgentRole::CHAT_CODING, AgentRole::CHAT_LOCAL ],
          mutation: true),
        legacy_chat(Mcp::Tools::EmergencyLandTool, feature_flag: :emergency_land, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::OpenInCodingModeTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::SubmitCodingChangesTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::RuntimeListSessionsTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ]),
        legacy_chat(Mcp::Tools::RuntimeStartTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::RuntimeStatusTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ]),
        legacy_chat(Mcp::Tools::RuntimeBuildOrReloadTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::RuntimeLaunchTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::RuntimeSnapshotTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::RuntimeInspectTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ]),
        legacy_chat(Mcp::Tools::RuntimeLogsTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ]),
        legacy_chat(Mcp::Tools::RuntimeAcquireControlTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::RuntimeReleaseControlTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::RuntimeInputTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::RuntimeCaptureArtifactTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::RuntimeStopTool, feature_flag: :coding_mode, required_roles: [ AgentRole::CHAT_CODING ], mutation: true),
        legacy_chat(Mcp::Tools::AdminOverviewTool, admin_only: true),
        legacy_chat(Mcp::Tools::AdminStuckJobsTool, admin_only: true),
        legacy_chat(Mcp::Tools::AdminQueueDetailTool, admin_only: true),
        legacy_chat(Mcp::Tools::AdminListProcessesTool, admin_only: true),
        legacy_chat(Mcp::Tools::AdminListRunsTool, admin_only: true),
        legacy_chat(Mcp::Tools::AdminListUsersTool, admin_only: true),
        legacy_chat(Mcp::Tools::AdminVersionTool, admin_only: true),
        legacy_chat(Mcp::Tools::ReadWorkerHealthTool, admin_only: true),
        legacy_chat(Mcp::Tools::OperationalDiagnosticsTools::ReadMetricsDiagnosticsTool, admin_only: true),
        legacy_chat(Mcp::Tools::OperationalDiagnosticsTools::ReadWorkerOccupancyTool, admin_only: true),
        legacy_chat(Mcp::Tools::OperationalDiagnosticsTools::ReadWorkflowTimelineTool, admin_only: true),
        legacy_chat(Mcp::Tools::OperationalDiagnosticsTools::ReadWorkflowWaterfallTool, admin_only: true),
        legacy_chat(Mcp::Tools::OperationalDiagnosticsTools::ReadAdmissionDiagnosticsTool, admin_only: true),
        legacy_chat(Mcp::Tools::OperationalDiagnosticsTools::DiagnoseRunQueueTool, admin_only: true),
        legacy_chat(Mcp::Tools::AdminReadOperationalLogsTool, admin_only: true),
        legacy_chat(Mcp::Tools::AdminMcpToolUsageTool, admin_only: true),
        legacy_chat(Mcp::Tools::AdminMaintenanceTasksTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminKillProcessTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminReapStaleRunsTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminPausePollingTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminUnpausePollingTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminPauseRunsTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminUnpauseRunsTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminClearGithubCacheTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminPauseUserSchedulingTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminUnpauseUserSchedulingTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminRetryStepTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminCleanupWorkspaceTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminRefreshInstallationsTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdminGithubAppInstallationDiagnosticTool, admin_only: true),
        legacy_chat(Mcp::Tools::ForceFailJobTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::ReconcileJobStateTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::ForceStateTransitionTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::CancelStaleWorkTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::RetireTerminalWorkUnitTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::ReenqueueWorkTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::RepairQueueAffinityTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::ForceRebaseTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::RestackEpicTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::ForceLandingRecheckTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::ManualAgenticRunTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::AdoptCurrentPrHeadTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::ReplacePrBranchWithWorkflowOutputTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::RetryFromCurrentPrBranchTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::RefreshPrChecksTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::RerunCiRepairTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::MarkCiRepairNoopTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::OverrideLandingBlockerOnceTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::WakeLandingQueueTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::InspectProviderCircuitTool, admin_only: true),
        legacy_chat(Mcp::Tools::RepairProviderCircuitEvidenceTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::ClearProviderCircuitTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::WakeProviderAdmissionTool, admin_only: true, mutation: true),
        legacy_chat(Mcp::Tools::ReadFileTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]),
        legacy_chat(Mcp::Tools::WriteFileTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        legacy_chat(Mcp::Tools::ListFilesTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]),
        legacy_chat(Mcp::Tools::RunCommandTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        legacy_chat(Mcp::Tools::GitDiffTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]),
        legacy_chat(Mcp::Tools::GitStatusTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ]),
        legacy_chat(Mcp::Tools::OpenInLocalModeTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        legacy_chat(Mcp::Tools::CancelLocalModeTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        legacy_chat(Mcp::Tools::CreateCodingJobTool, feature_flag: :local_mode, required_roles: [ AgentRole::CHAT_LOCAL ], mutation: true),
        legacy_chat(Mcp::Tools::UpdatePinnedContextTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::RemovePinnedContextTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ListChatsTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ListRepositoriesTool, tier: :deferred),
        legacy_chat(Mcp::Tools::GetJobDiffTool, tier: :deferred),
        legacy_chat(Mcp::Tools::UpdateJobTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ListJobWorkflowsTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ReadWorkflowTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ReadRunTranscriptTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ListArtifactsTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ReadArtifactTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ExplainStuckJobTool, tier: :deferred),
        legacy_chat(Mcp::Tools::AssignJobToEpicTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ListOpenIssuesTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ListOpenPrsTool, tier: :deferred),
        legacy_chat(Mcp::Tools::SearchChatsTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ReadChatMessagesTool, tier: :deferred),
        legacy_chat(Mcp::Tools::SendChatMessageTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::SpawnChatsTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ListTagsTool, tier: :deferred),
        legacy_chat(Mcp::Tools::CreateTagTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::AddJobTagTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::RemoveJobTagTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::RebaseJobTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ReopenJobTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::PollJobFeedbackTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::RunVisualReviewTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::CheckJobMergeabilityTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::DelegateIssueTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ReadPrTool, tier: :deferred),
        legacy_chat(Mcp::Tools::UnapproveJobTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::RemoveJobFromEpicTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::StartEpicTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::MoveEpicToBacklogTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ArchiveEpicTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::UpdateEpicTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::AddEpicDependencyTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::RemoveEpicDependencyTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::AddJobDependencyTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::RemoveJobDependencyTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ListRepoDocumentsTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ReadRepoDocumentTool, tier: :deferred),
        legacy_chat(Mcp::Tools::CreateRepoDocumentTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::DeleteRepoDocumentTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ListChatMediaTool, tier: :deferred),
        legacy_chat(Mcp::Tools::SubmitArtifactTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ScheduleWakeupTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ListWakeupsTool, tier: :deferred),
        legacy_chat(Mcp::Tools::CancelWakeupTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::PauseLandingQueueTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ResumeLandingQueueTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ReadQueueTool, tier: :deferred, admin_only: true),
        legacy_chat(Mcp::Tools::SearchSyrusDocsTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ListDeliveryTracksTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ResolveDeliveryPolicyTool, tier: :deferred),
        legacy_chat(Mcp::Tools::SelectJobDeliveryTrackTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ListRefMovementActionsTool, tier: :deferred),
        legacy_chat(Mcp::Tools::DispatchRefMovementActionTool, tier: :deferred, mutation: true),
        legacy_chat(Mcp::Tools::ReadRefMovementStatusTool, tier: :deferred),
        legacy_chat(Mcp::Tools::ClassifyPullRequestTool, tier: :deferred),
        legacy_chat(Mcp::Tools::IngestPullRequestTool, tier: :deferred, mutation: true)
      ]
    end

    # Coworker chats are deliberately deny-by-default. Every entry here names
    # the persisted grant required to advertise it; ordinary chat/admin status
    # never widens this surface.
    def coworker_entries
      [
        legacy_coworker(Mcp::Tools::AttachRepositoryTool, capability: "code.read", interactive_only: true, mutation: true),
        legacy_coworker(Mcp::Tools::DetachRepositoryTool, capability: "code.read", interactive_only: true, mutation: true),
        legacy_coworker(Mcp::Tools::ListRepositoryFilesTool, capability: "code.read"),
        legacy_coworker(Mcp::Tools::ReadRepositoryFileTool, capability: "code.read"),
        legacy_coworker(Mcp::Tools::SearchRepositoryCodeTool, capability: "code.read"),
        legacy_coworker(Mcp::Tools::GetJobDiffTool, capability: "code.read"),
        legacy_coworker(Mcp::Tools::ReadPrTool, capability: "code.read"),
        legacy_coworker(Mcp::Tools::AskUserQuestionTool, capability: "chat.message_owner", interactive_only: true, mutation: true, ungated: true),
        legacy_coworker(Mcp::Tools::SuggestNextStepTool, capability: "chat.message_owner", interactive_only: true, mutation: true, ungated: true),
        coworker(Mcp::Tools::DiscoverCoworkerCapabilitiesTool,
          tier: :deferred, capability: "chat.message_owner", ungated: true),
        legacy_coworker(Mcp::Tools::ListJobsTool, capability: "syrus.read_jobs"),
        legacy_coworker(Mcp::Tools::SearchJobsTool, capability: "syrus.read_jobs"),
        legacy_coworker(Mcp::Tools::ReadJobTool, capability: "syrus.read_jobs"),
        legacy_coworker(Mcp::Tools::ProposeJobTool, capability: "syrus.propose_job", mutation: true),
        legacy_coworker(Mcp::Tools::ProposeEpicWithJobsTool, capability: "syrus.propose_job", mutation: true),
        legacy_coworker(Mcp::Tools::ListChatsTool, tier: :deferred, capability: "chats.read_shared"),
        legacy_coworker(Mcp::Tools::SearchChatsTool, tier: :deferred, capability: "chats.read_shared"),
        legacy_coworker(Mcp::Tools::ReadChatMessagesTool, tier: :deferred, capability: "chats.read_shared"),
        legacy_coworker(Mcp::Tools::AdminReadOperationalLogsTool, capability: "ops.read_logs", default_policy: :ask),
        legacy_coworker(Mcp::Tools::ReadWorkerHealthTool, capability: "ops.read_logs", default_policy: :ask),
        legacy_coworker(Mcp::Tools::ReadBackendExceptionEventsTool, capability: "ops.read_logs", default_policy: :ask),
        legacy_coworker(Mcp::Tools::ReadBrowserErrorEventsTool, capability: "ops.read_logs", default_policy: :ask),
        legacy_coworker(Mcp::Tools::ReadPerformanceLogEventsTool, capability: "ops.read_logs", default_policy: :ask),
        legacy_coworker(Mcp::Tools::OperationalDiagnosticsTools::ReadMetricsDiagnosticsTool, capability: "ops.read_logs", default_policy: :ask),
        legacy_coworker(Mcp::Tools::OperationalDiagnosticsTools::ReadWorkerOccupancyTool, capability: "ops.read_logs", default_policy: :ask),
        legacy_coworker(Mcp::Tools::OperationalDiagnosticsTools::ReadWorkflowTimelineTool, capability: "ops.read_logs", default_policy: :ask),
        legacy_coworker(Mcp::Tools::OperationalDiagnosticsTools::ReadWorkflowWaterfallTool, capability: "ops.read_logs", default_policy: :ask),
        legacy_coworker(Mcp::Tools::OperationalDiagnosticsTools::ReadAdmissionDiagnosticsTool, capability: "ops.read_logs", default_policy: :ask),
        legacy_coworker(Mcp::Tools::OperationalDiagnosticsTools::DiagnoseRunQueueTool, capability: "ops.read_logs", default_policy: :ask)
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

      target_prepare_roles = [
        AgentRole::WORKFLOW_IMPLEMENT,
        AgentRole::WORKFLOW_REBASE_CONFLICT,
        AgentRole::WORKFLOW_MANUAL
      ]

      concern_reporting_roles = [
        AgentRole::WORKFLOW_IMPLEMENT,
        AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
        AgentRole::WORKFLOW_REBASE_CONFLICT,
        AgentRole::WORKFLOW_MANUAL
      ]

      metadata_roles = [
        AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
        AgentRole::WORKFLOW_MANUAL
      ]

      [
        legacy_workflow(Mcp::Tools::ReadLiveStateTool, required_roles: workflow_roles),
        legacy_workflow(Mcp::Tools::GetCoverageReportTool, required_roles: workflow_roles),
        legacy_workflow(Mcp::Tools::ReadRunWorkerHealthTool, required_roles: workflow_roles),
        legacy_workflow(Mcp::Tools::StartPreviewTool, required_roles: workflow_roles, mutation: true),
        legacy_workflow(Mcp::Tools::StopPreviewTool, required_roles: workflow_roles, mutation: true),
        legacy_workflow(Mcp::Tools::ReadPreviewLogTool, required_roles: workflow_roles),
        # Reviewers only see a diff (and, for visual review, a running preview)
        # and cannot distinguish real main-branch regressions from transient
        # infrastructure failures, so granting these would produce false quorum
        # signals.
        legacy_workflow(Mcp::Tools::ReportCannotProceedTool, capability: :report_cannot_proceed, required_roles: concern_reporting_roles, mutation: true),
        legacy_workflow(Mcp::Tools::ReportMainConcernTool, required_roles: concern_reporting_roles, mutation: true),
        legacy_workflow(Mcp::Tools::RecordIsolatedReproTool, required_roles: concern_reporting_roles, mutation: true),
        legacy_workflow(Mcp::Tools::SubmitSummaryTool, capability: :submit_summary, required_roles: summary_roles, mutation: true),
        legacy_workflow(Mcp::Tools::SubmitTestPlanTool, capability: :submit_test_plan, required_roles: summary_roles, mutation: true),
        legacy_workflow(Mcp::Tools::SubmitReportTool, capability: :submit_report, required_roles: summary_roles, step_kinds: %w[submit_report], mutation: true),
        legacy_workflow(Mcp::Tools::InvestigationProposeJobTool, capability: :propose_job, required_roles: [
          AgentRole::WORKFLOW_IMPLEMENT,
          AgentRole::WORKFLOW_SUMMARY_TEST_PLAN
        ], step_kinds: %w[investigate submit_report], mutation: true),
        legacy_workflow(Mcp::Tools::SearchJobsTool, required_roles: workflow_roles),
        legacy_workflow(Mcp::Tools::ListJobsTool, required_roles: workflow_roles),
        legacy_workflow(Mcp::Tools::ListOpenPrsTool, required_roles: workflow_roles),
        legacy_workflow(Mcp::Tools::ReadPrTool, required_roles: workflow_roles),
        legacy_workflow(Mcp::Tools::ListOpenIssuesTool, required_roles: workflow_roles),
        legacy_workflow(SyrusMcp::SubmitArtifactTool, capability: :submit_artifact, required_roles: artifact_roles, mutation: true),
        legacy_workflow(SyrusMcp::RunTargetPrepareTool, capability: :run_target_prepare, required_roles: target_prepare_roles, mutation: true),
        # Only the implementing agent may add work to its own workflow, and
        # WorkflowPatch bounds what "add" means (workflow-engine-v3 A7).
        legacy_workflow(SyrusMcp::PatchWorkflowTool, capability: :patch_workflow, required_roles: [
          AgentRole::WORKFLOW_IMPLEMENT,
          AgentRole::WORKFLOW_MANUAL
        ], mutation: true),
        legacy_workflow(SyrusMcp::SubmitVisualArtifactTool, capability: :submit_visual_artifact, required_roles: visual_artifact_roles, mutation: true),
        legacy_workflow(SyrusMcp::ListArtifactsTool, required_roles: visual_artifact_roles),
        legacy_workflow(SyrusMcp::ReadArtifactTool, required_roles: visual_artifact_roles),
        legacy_workflow(Mcp::Tools::SubmitJobMetadataTool, capability: :submit_job_metadata, required_roles: metadata_roles, step_kinds: %w[refresh_job_metadata], mutation: true),
        legacy_workflow(Mcp::Tools::SubmitAdversarialReviewTool, capability: :submit_adversarial_review, required_roles: [
          AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER,
          AgentRole::WORKFLOW_MANUAL
        ], mutation: true),
        legacy_workflow(Mcp::Tools::SubmitSecurityReviewTool, capability: :submit_security_review, required_roles: [
          AgentRole::WORKFLOW_SECURITY_REVIEWER,
          AgentRole::WORKFLOW_MANUAL
        ], mutation: true),
        legacy_workflow(Mcp::Tools::SubmitVisualReviewTool, capability: :submit_visual_review, required_roles: [
          AgentRole::WORKFLOW_VISUAL_REVIEWER,
          AgentRole::WORKFLOW_MANUAL
        ], mutation: true)
      ]
    end

    def agent_insight_entries
      [
        legacy_entry(Mcp::Tools::ReadLiveStateTool, surface: :agent_insight),
        legacy_entry(Mcp::Tools::ReadRunWorkerHealthTool, surface: :agent_insight)
      ]
    end

    def chat(tool, tier: :essential, **metadata)
      entry(tool, surface: :chat, tier: tier, **metadata)
    end

    def workflow(tool, **metadata)
      entry(tool, surface: :workflow, **metadata)
    end

    def coworker(tool, tier: :essential, **metadata)
      metadata[:required_roles] ||= [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]
      entry(tool, surface: :coworker, tier: tier, **metadata)
    end

    # Compatibility is declared beside the registrations it covers so adding
    # a new tool through the normal builders fails descriptor validation.
    def legacy_chat(tool, **metadata) = chat(tool, **metadata, compatibility_descriptor: true)
    def legacy_workflow(tool, **metadata) = workflow(tool, **metadata, compatibility_descriptor: true)
    def legacy_coworker(tool, **metadata) = coworker(tool, **metadata, compatibility_descriptor: true)
    def legacy_entry(tool, **metadata) = entry(tool, **metadata, compatibility_descriptor: true)

    def permission_management_chat(tool, mutation: false)
      descriptor = Permissions::CapabilityDescriptorAdapter.for_registry_entry(
        tool_name: tool_name_for(tool),
        capability: "syrus.permissions",
        mutation: mutation,
        required_roles: AgentRole::CHAT_ROLES
      )
      chat(tool, tier: :deferred, mutation:, descriptor:)
    end

    def entry(tool, surface:, tier: nil, admin_only: false, feature_flag: nil, feature_flags_by_role: nil,
              required_roles: [], step_kinds: [], capability: nil, interactive_only: false, mutation: false, ungated: false,
              descriptor: nil, compatibility_descriptor: false, default_policy: nil)
      tool_name = tool_name_for(tool)
      explicit_descriptor = descriptor.present?
      Entry.new(
        tool: tool,
        surface: surface.to_sym,
        tier: tier&.to_sym,
        admin_only: admin_only,
        feature_flag: feature_flag&.to_sym,
        feature_flags_by_role: normalize_feature_flags_by_role(feature_flags_by_role),
        required_roles: Array(required_roles).freeze,
        step_kinds: Array(step_kinds).map(&:to_s).freeze,
        capability: capability&.to_sym,
        interactive_only: interactive_only,
        mutation: mutation,
        ungated: ungated,
        descriptor: Permissions::CapabilityDescriptorAdapter.for_registry_entry(
          tool_name: tool_name,
          capability: capability,
          mutation: mutation,
          required_roles: required_roles,
          admin_only: admin_only,
          descriptor: descriptor,
          default_policy: default_policy
        ),
        explicit_descriptor: explicit_descriptor,
        compatibility_descriptor: compatibility_descriptor
      )
    end

    def normalize_feature_flags_by_role(feature_flags_by_role)
      return nil if feature_flags_by_role.blank?

      feature_flags_by_role.to_h.transform_keys(&:to_s).transform_values(&:to_sym).freeze
    end
  end
end
