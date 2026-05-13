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
    def initialize(session_id: ENV["SYRUS_CHAT_SESSION_ID"])
      raise KeyError, "SYRUS_CHAT_SESSION_ID is required" if session_id.blank?

      @chat_session = ChatSession.find(session_id)
    end

    def run
      server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [
          ProposeIssueTool,
          ListProposalsTool,
          DeleteProposalTool,
          ReadJobTool,
          ListJobsTool,
          CancelJobTool,
          RetryJobTool,
          RebaseJobTool,
          ReadPrTool,
          RepoInfoTool,
          ReadSceneTool,
          DrawShapeTool,
          DrawTextTool,
          DrawArrowTool,
          MoveElementTool,
          DeleteElementTool,
          ClearCanvasTool,
          UpdateSceneTool,
          ScheduleRecurringTool
        ],
        server_context: { chat_session: @chat_session }
      )
      transport = MCP::Server::Transports::StdioTransport.new(server)

      Signal.trap("TERM") { transport.close; exit 0 }

      transport.open
    end
  end
end
