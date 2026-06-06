require "mcp"

module SyrusChatMcp
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
      SetBookmarkTool,
      ProposeEpicWithJobsTool,
      ListProposalsTool,
      DeleteProposalTool,
      ReadEpicTool,
      ReadJobTool,
      ListJobsTool,
      CancelJobTool,
      RetryJobTool,
      RebaseJobTool,
      ReadPrTool,
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
      ScheduleRecurringTool
    ].freeze

    def self.tool_names
      TOOLS.map { |tool| tool.name.demodulize.sub(/Tool\z/, "").underscore }
    end

    def initialize(session_id: ENV["SYRUS_CHAT_SESSION_ID"])
      raise KeyError, "SYRUS_CHAT_SESSION_ID is required" if session_id.blank?

      @chat_session = ChatSession.find(session_id)
    end

    def run
      server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: TOOLS,
        server_context: { chat_session: @chat_session }
      )
      transport = MCP::Server::Transports::StdioTransport.new(server)

      Signal.trap("TERM") { transport.close; exit 0 }

      transport.open
    end
  end
end
