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
  #         "env": { "SYRUS_CHAT_SESSION_ID": "123" },
  #         "alwaysLoad": true
  #       }
  #     }
  #   }
  #
  # `alwaysLoad: true` keeps these proposal tools in the active MCP toolset
  # across resumed sessions, matching the existing run sidecar convention.
  class Sidecar
    TOOLS = [
      AttachRepositoryTool,
      ProposeIssueTool,
      ProposeEpicTool,
      ProposeJobTool,
      RenameChatTool,
      UpdatePinnedContextTool,
      RemovePinnedContextTool,
      AskUserQuestionTool,
      SetBookmarkTool,
      ProposeEpicWithJobsTool,
      ListChatsTool,
      ListProposalsTool,
      DeleteProposalTool,
      ListEpicsTool,
      ReadEpicTool,
      StartEpicTool,
      MoveEpicToBacklogTool,
      ArchiveEpicTool,
      UpdateEpicTool,
      ReadJobTool,
      UpdateJobTool,
      ListJobWorkflowsTool,
      ReadWorkflowTool,
      ReadRunTranscriptTool,
      SearchChatsTool,
      ReadChatMessagesTool,
      ListJobsTool,
      SearchJobsTool,
      ApproveJobTool,
      UnapproveJobTool,
      SetJobPriorityTool,
      AssignJobToEpicTool,
      RemoveJobFromEpicTool,
      CancelJobTool,
      RetryJobTool,
      RebaseJobTool,
      SubmitChatFeedbackTool,
      ReadPrTool,
      WriteMemoryTool,
      ReadMemoryTool,
      SearchMemoriesTool,
      ListMemoriesTool,
      DeleteMemoryTool,
      PublishMemoryTool,
      UnpublishMemoryTool,
      RepoInfoTool,
      ListRepoDocumentsTool,
      ReadRepoDocumentTool,
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
      ListScheduledTasksTool,
      PauseScheduledTaskTool,
      ResumeScheduledTaskTool,
      DeleteScheduledTaskTool,
      ReadQueueTool
    ].freeze

    def self.tool_names
      TOOLS.map { |tool| tool.name.demodulize.sub(/Tool\z/, "").underscore }
    end

    def initialize(session_id: ENV["SYRUS_CHAT_SESSION_ID"], current_message_id: ENV["SYRUS_CHAT_CURRENT_MESSAGE_ID"])
      raise KeyError, "SYRUS_CHAT_SESSION_ID is required" if session_id.blank?

      @chat_session = ChatSession.find(session_id)
      @current_message = if current_message_id.present?
        @chat_session.messages.find_by(id: current_message_id)
      else
        CurrentMessage.new(@chat_session)
      end
    end

    def run
      server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: TOOLS,
        server_context: { chat_session: @chat_session, current_message: @current_message }.compact
      )
      transport = MCP::Server::Transports::StdioTransport.new(server)

      Signal.trap("TERM") { transport.close; exit 0 }

      transport.open
    end
  end
end
