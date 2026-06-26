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
  # The chat harness registers this binary twice: an essential `alwaysLoad`
  # server whose schemas are injected at turn start, and a deferred server
  # whose schemas are resolved through Claude Code ToolSearch on demand.
  class Sidecar
    ESSENTIAL_TOOLS = [
      AttachRepositoryTool,
      ProposeIssueTool,
      ProposeEpicTool,
      ProposeJobTool,
      SetBookmarkTool,
      ProposeEpicWithJobsTool,
      ListProposalsTool,
      DeleteProposalTool,
      ListEpicsTool,
      ReadEpicTool,
      ReadJobTool,
      ListJobsTool,
      SearchJobsTool,
      ApproveJobTool,
      SetJobPriorityTool,
      AssignJobToEpicTool,
      CancelJobTool,
      RetryJobTool,
      SubmitChatFeedbackTool,
      WriteMemoryTool,
      ReadMemoryTool,
      RepoInfoTool
    ].freeze

    DEFERRED_TOOLS = [
      RenameChatTool,
      UpdatePinnedContextTool,
      RemovePinnedContextTool,
      AskUserQuestionTool,
      ListChatsTool,
      ListRepositoriesTool,
      AddRepoNoteTool,
      ReadRepoNotesTool,
      RemoveRepoNoteTool,
      GetJobDiffTool,
      UpdateJobTool,
      ListJobWorkflowsTool,
      ReadWorkflowTool,
      ReadRunTranscriptTool,
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
      ClearCanvasTool,
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

    TOOLS = (ESSENTIAL_TOOLS + DEFERRED_TOOLS).freeze
    ADMIN_TOOLS = DEFERRED_TOOLS.select { |tool| tool.name.demodulize.start_with?("Admin") }.freeze

    def self.tool_names(chat_session = nil, tier: :all)
      tools = chat_session ? tools_for(chat_session, tier: tier) : tools_for_tier(tier)
      tools.map { |tool| tool.name.demodulize.sub(/Tool\z/, "").underscore }
    end

    def self.tools_for(chat_session, tier: :all)
      tools_for_tier(tier).select do |tool|
        !admin_tool?(tool) || chat_session.user.admin?
      end
    end

    def self.tools_for_tier(tier)
      case tier.to_s
      when "essential"
        ESSENTIAL_TOOLS
      when "deferred"
        DEFERRED_TOOLS
      when "all"
        TOOLS
      else
        raise ArgumentError, "unknown chat MCP tool tier: #{tier.inspect}"
      end
    end

    def self.admin_tool?(tool)
      ADMIN_TOOLS.include?(tool)
    end

    def initialize(session_id: ENV["SYRUS_CHAT_SESSION_ID"],
                   current_message_id: ENV["SYRUS_CHAT_CURRENT_MESSAGE_ID"],
                   tool_tier: ENV.fetch("SYRUS_CHAT_MCP_TOOL_TIER", "all"),
                   server_name: ENV.fetch("SYRUS_CHAT_MCP_SERVER_NAME", "syrus-chat-sidecar"))
      raise KeyError, "SYRUS_CHAT_SESSION_ID is required" if session_id.blank?

      @chat_session = ChatSession.find(session_id)
      @tool_tier = tool_tier
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
        tools: self.class.tools_for(@chat_session, tier: @tool_tier),
        server_context: { chat_session: @chat_session, current_message: @current_message }.compact
      )
      transport = MCP::Server::Transports::StdioTransport.new(server)

      Signal.trap("TERM") { transport.close; exit 0 }

      transport.open
    end
  end
end
