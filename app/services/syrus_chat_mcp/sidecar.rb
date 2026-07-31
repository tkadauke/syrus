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
  #         "args": ["--tier", "essential"],
  #         "env": {
  #           "SYRUS_CHAT_SESSION_ID": "123",
  #           "SYRUS_CHAT_MCP_TOOL_TIER": "essential",
  #           "SYRUS_CHAT_MCP_SERVER_NAME": "syrus-chat-sidecar"
  #         },
  #         "alwaysLoad": true
  #       },
  #       "syrus-chat-deferred-sidecar": {
  #         "type": "stdio",
  #         "command": "/app/bin/syrus-chat-sidecar",
  #         "args": ["--tier", "deferred"],
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
    TOOLS = McpToolRegistry.tools(surface: :chat, tier: :essential).freeze
    ADMIN_TOOLS = McpToolRegistry.entries.select { |entry| entry.surface == :chat && entry.admin_only }.map(&:tool).freeze
    WALKTHROUGH_TOOLS = McpToolRegistry.entries.select { |entry| entry.surface == :chat && entry.feature_flag == :video_walkthroughs }.map(&:tool).freeze
    CODING_TOOLS = McpToolRegistry.entries.select { |entry| entry.surface == :chat && entry.required_roles.include?(AgentRole::CHAT_CODING) }.map(&:tool).freeze
    LOCAL_MODE_TOOLS = McpToolRegistry.entries.select { |entry| entry.surface == :chat && entry.required_roles.include?(AgentRole::CHAT_LOCAL) }.map(&:tool).freeze

    def self.tool_names(chat_session = nil, tier: nil)
      return DeferredSidecar.tool_names(chat_session) if tier.to_s == "deferred"

      tools = chat_session ? tools_for(chat_session, tier: tier) : McpToolRegistry.tools(surface: :chat, tier: :essential)
      tools.map { |tool| tool.name.demodulize.sub(/Tool\z/, "").underscore }
    end

    def self.tools_for(chat_session, tier: nil)
      return DeferredSidecar.tools_for(chat_session) if tier.to_s == "deferred"

      tools = tools_for_session(TOOLS, chat_session)
      tools << authorize_tool(ExplainStuckJobTool) if tier.to_s == "all" && !tools.include?(ExplainStuckJobTool)
      tools
    end

    def self.tools_for_session(tools, chat_session)
      context = McpToolContext.from_chat_session(chat_session)
      allowed = McpToolPolicy.for(context)
      tools.select { |tool| allowed.include?(tool) }.map { |tool| authorize_tool(tool) }
    end

    def self.authorize_tool(tool)
      tool.extend(AuthorizationSupport) unless tool.singleton_class < AuthorizationSupport
      tool.singleton_class.prepend(AuthorizationSupport::ToolDispatch) unless tool.singleton_class < AuthorizationSupport::ToolDispatch
      tool
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
    DEFERRED_TOOLS = McpToolRegistry.tools(surface: :chat, tier: :deferred).freeze

    def self.tool_names(chat_session = nil)
      tools = chat_session ? tools_for(chat_session) : McpToolRegistry.tools(surface: :chat, tier: :deferred)
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
