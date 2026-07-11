require "mcp"

module SyrusChatMcp
  class CurrentMessage
    def initialize(chat_session)
      @chat_session = chat_session
    end

    def update_columns(attributes)
      message&.update_columns(attributes)
    end

    private

    def message
      @chat_session.messages.where(role: "assistant").order(created_at: :desc, id: :desc).first
    end
  end

  # Per-chat-session MCP server, spawned over stdio by the chat agent turn.
  #
  # Expected mcp.json shape:
  #
  #   {
  #     "mcpServers": {
  #       "syrus-chat-sidecar": {
  #         "type": "stdio",
  #         "command": "/app/bin/syrus-chat-sidecar",
  #         "env": {
  #           "SYRUS_CHAT_SESSION_ID": "123",
  #           "SYRUS_CHAT_MCP_TOOL_TIER": "essential",
  #           "SYRUS_CHAT_MCP_SERVER_NAME": "syrus-chat-sidecar"
  #         },
  #         "alwaysLoad": true
  #       },
  #       "syrus-chat-deferred-sidecar": {
  #         "type": "stdio",
  #         "command": "/app/bin/syrus-chat-deferred-sidecar",
  #         "env": {
  #           "SYRUS_CHAT_SESSION_ID": "123",
  #           "SYRUS_CHAT_MCP_TOOL_TIER": "deferred",
  #           "SYRUS_CHAT_MCP_SERVER_NAME": "syrus-chat-deferred-sidecar"
  #         }
  #       }
  #     }
  #   }
  #
  # The chat harness registers two MCP servers: this `alwaysLoad` sidecar
  # for core tools whose schemas are injected at turn start, and a deferred
  # sidecar whose schemas are resolved through Claude Code ToolSearch on
  # demand.
  class Sidecar
    ADMIN_TOOLS = [
      AdminOverviewTool,
      AdminStuckJobsTool,
      AdminQueueDetailTool,
      AdminListProcessesTool,
      AdminListRunsTool,
      AdminListUsersTool,
      AdminVersionTool,
      AdminKillProcessTool,
      AdminReapStaleRunsTool,
      AdminPausePollingTool,
      AdminUnpausePollingTool,
      AdminPauseRunsTool,
      AdminUnpauseRunsTool,
      AdminClearGithubCacheTool,
      AdminPauseUserSchedulingTool,
      AdminUnpauseUserSchedulingTool,
      AdminRetryStepTool,
      AdminCleanupWorkspaceTool,
      AdminRefreshInstallationsTool
    ].freeze

    # Gated by the `video_walkthroughs` labs Feature (see tools_for_session).
    WALKTHROUGH_TOOLS = [
      GetWalkthroughAnalysisTool,
      AnalyzeWalkthroughSegmentTool,
      ReadWalkthroughFrameTool
    ].freeze

    # Gated by the `coding_mode` labs Feature AND chat.coding? (see tools_for_session).
    CODING_TOOLS = [
      CompleteImplementStepTool,
      SubmitCodingChangesTool
    ].freeze

    # Gated by the `local_mode` labs Feature AND chat_session.mode == "local"
    # (see tools_for_session). Tools dispatch through the daemon tunnel.
    LOCAL_MODE_TOOLS = [
      ReadFileTool,
      WriteFileTool,
      ListFilesTool,
      RunCommandTool,
      GitDiffTool,
      GitStatusTool,
      OpenInLocalModeTool,
      CancelLocalModeTool,
      CreateCodingJobTool,
      CompleteImplementStepTool
    ].freeze

    TOOLS = [
      AttachRepositoryTool,
      ProposeEpicTool,
      ProposeJobTool,
      ProposeEpicWithJobsTool,
      ListProposalsTool,
      DeleteProposalTool,
      SetBookmarkTool,
      ListJobsTool,
      SearchJobsTool,
      ReadJobTool,
      ListEpicsTool,
      ReadEpicTool,
      ApproveJobTool,
      CancelJobTool,
      RetryJobTool,
      SetJobPriorityTool,
      WriteMemoryTool,
      ReadMemoryTool,
      RepoInfoTool,
      SubmitChatFeedbackTool,
      RenameChatTool,
      SuggestNextStepTool,
      AskUserQuestionTool,
      *CODING_TOOLS,
      *ADMIN_TOOLS,
      *LOCAL_MODE_TOOLS
    ].freeze

    def self.tool_names(chat_session = nil, tier: nil)
      return DeferredSidecar.tool_names(chat_session) if tier.to_s == "deferred"

      tools = chat_session ? tools_for(chat_session) : TOOLS
      tools.map { |tool| tool.name.demodulize.sub(/Tool\z/, "").underscore }
    end

    def self.tools_for(chat_session, tier: nil)
      return DeferredSidecar.tools_for(chat_session) if tier.to_s == "deferred"

      tools_for_session(TOOLS, chat_session)
    end

    def self.tools_for_session(tools, chat_session)
      tools = tools.select do |tool|
        !admin_tool?(tool) || chat_session.user.admin?
      end
      # Labs flag: when walkthroughs are disabled the tools vanish from the
      # advertised set entirely — the agent never sees them, so it cannot
      # call them against pre-existing walkthrough rows either.
      tools = tools.reject { |tool| walkthrough_tool?(tool) } unless Feature.video_walkthroughs_enabled?
      # Labs flag: coding tools only appear when the flag is on AND the
      # session is in coding mode, so the agent cannot call them from
      # planning mode even if the feature is enabled instance-wide.
      tools = tools.reject { |tool| coding_tool?(tool) } unless coding_mode_session?(chat_session)
      # Local mode tools are only advertised when the local_mode feature is
      # enabled AND the session is in local mode. The daemon connectivity check
      # happens at call time (a disconnected daemon returns a clear error).
      tools = tools.reject { |tool| local_mode_tool?(tool) } unless local_mode_active?(chat_session)
      tools.map { |tool| authorize_tool(tool) }
    end

    def self.authorize_tool(tool)
      tool.extend(AuthorizationSupport) unless tool.singleton_class < AuthorizationSupport
      tool.singleton_class.prepend(AuthorizationSupport::ToolDispatch) unless tool.singleton_class < AuthorizationSupport::ToolDispatch
      tool
    end

    def self.admin_tool?(tool)
      ADMIN_TOOLS.include?(tool)
    end

    def self.walkthrough_tool?(tool)
      WALKTHROUGH_TOOLS.include?(tool)
    end

    def self.coding_tool?(tool)
      CODING_TOOLS.include?(tool)
    end

    def self.coding_mode_session?(chat_session)
      Feature.coding_mode_enabled? && chat_session.coding?
    end

    def self.local_mode_tool?(tool)
      LOCAL_MODE_TOOLS.include?(tool)
    end

    def self.local_mode_active?(chat_session)
      Feature.local_mode_enabled? && chat_session&.mode == "local"
    end

    def self.server_name
      "syrus-chat-sidecar"
    end

    def initialize(session_id: ENV["SYRUS_CHAT_SESSION_ID"],
                   current_message_id: ENV["SYRUS_CHAT_CURRENT_MESSAGE_ID"],
                   server_name: ENV.fetch("SYRUS_CHAT_MCP_SERVER_NAME", self.class.server_name),
                   **)
      raise KeyError, "SYRUS_CHAT_SESSION_ID is required" if session_id.blank?

      @chat_session = ChatSession.find(session_id)
      @server_name = server_name
      @current_message = if current_message_id.present?
        @chat_session.messages.find_by(id: current_message_id)
      else
        CurrentMessage.new(@chat_session)
      end
    end

    def run
      server = MCP::Server.new(
        name: @server_name,
        tools: self.class.tools_for(@chat_session),
        server_context: { chat_session: @chat_session, current_message: @current_message }.compact
      )
      transport = MCP::Server::Transports::StdioTransport.new(server)

      Signal.trap("TERM") { transport.close; exit 0 }

      transport.open
    end
  end

  class DeferredSidecar < Sidecar
    DEFERRED_TOOLS = [
      UpdatePinnedContextTool,
      RemovePinnedContextTool,
      ListChatsTool,
      ListRepositoriesTool,
      GetJobDiffTool,
      UpdateJobTool,
      ListJobWorkflowsTool,
      ReadWorkflowTool,
      ReadRunTranscriptTool,
      AssignJobToEpicTool,
      ListOpenIssuesTool,
      ListOpenPrsTool,
      SearchChatsTool,
      ReadChatMessagesTool,
      GetSpendingTool,
      ListTagsTool,
      CreateTagTool,
      AddJobTagTool,
      RemoveJobTagTool,
      RebaseJobTool,
      ReopenJobTool,
      PollJobFeedbackTool,
      CheckJobMergeabilityTool,
      DelegateIssueTool,
      ReadPrTool,
      UnapproveJobTool,
      RemoveJobFromEpicTool,
      StartEpicTool,
      MoveEpicToBacklogTool,
      ArchiveEpicTool,
      UpdateEpicTool,
      AddEpicDependencyTool,
      RemoveEpicDependencyTool,
      AddJobDependencyTool,
      RemoveJobDependencyTool,
      SearchMemoriesTool,
      ListMemoriesTool,
      DeleteMemoryTool,
      PublishMemoryTool,
      UnpublishMemoryTool,
      ListRepoDocumentsTool,
      ReadRepoDocumentTool,
      CreateRepoDocumentTool,
      DeleteRepoDocumentTool,
      ReadSceneTool,
      DrawShapeTool,
      DrawTextTool,
      DrawLineTool,
      DrawArrowTool,
      DrawFreedrawTool,
      DrawFrameTool,
      DrawEmbedTool,
      DrawImageTool,
      MoveElementTool,
      DeleteElementTool,
      SaveCanvasTool,
      ClearCanvasTool,
      LoadCanvasTool,
      UpdateSceneTool,
      ScheduleRecurringTool,
      ScheduleWakeupTool,
      ListWakeupsTool,
      CancelWakeupTool,
      ListScheduledTasksTool,
      PauseScheduledTaskTool,
      ResumeScheduledTaskTool,
      DeleteScheduledTaskTool,
      FireScheduledTaskNowTool,
      PauseLandingQueueTool,
      ResumeLandingQueueTool,
      ReadQueueTool,
      GetWalkthroughAnalysisTool,
      AnalyzeWalkthroughSegmentTool,
      ReadWalkthroughFrameTool
    ].freeze

    def self.tool_names(chat_session = nil)
      tools = chat_session ? tools_for(chat_session) : DEFERRED_TOOLS
      tools.map { |tool| tool.name.demodulize.sub(/Tool\z/, "").underscore }
    end

    def self.tools_for(chat_session)
      tools_for_session(DEFERRED_TOOLS, chat_session)
    end

    def self.server_name
      "syrus-chat-deferred-sidecar"
    end
  end
end
