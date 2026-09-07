require "mcp"
require "json"

module SyrusBrowser
  # Coding Mode chat's entry point onto the same browser_* MCP tools the
  # workflow visual_review step already uses (see McpToolSet) -- the same
  # ScreenshotTool/ClickTool/etc. classes, just reached through a second
  # aggregator gated to a different surface. Every tool's own "which session
  # do I operate on" / "where does captured evidence go" resolution
  # (SessionContext / ArtifactSinks) is what actually makes a call behave
  # correctly for this surface; this class only decides *when the tools are
  # offered at all*.
  #
  # Gated to Coding Mode: a planning chat has no writable checkout or dev
  # server for these tools to act on, and Local Mode routes browser control
  # through its own daemon (a third, materially different backend --
  # explicitly out of scope here; see SessionContext).
  class ChatToolSet
    def self.available_for?(chat_session, tier:)
      chat_session.coding? && %i[essential deferred].include?(tier.to_sym)
    end

    def self.tool_definitions(tier:)
      McpToolSet.tool_definitions
    end

    def handle(tool_name, params, server_context)
      McpToolSet.new.handle(tool_name, params, server_context)
    end
  end
end
