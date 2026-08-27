module SyrusClaudeAgent
  class Engine < ::Rails::Engine
    # after_initialize runs after Zeitwerk is fully active, ensuring
    # Syrus::PluginRegistry (autoloaded from lib/) is resolvable.
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "claude_agent",
        display_name:    "Claude Agent",
        version:         SyrusClaudeAgent::VERSION,
        description:     "Runs workflow and chat turns through Claude.",
        long_description: "Claude Agent connects Syrus workflows and chats to the Claude CLI/provider adapter. It handles agent invocation, transcript capture, provider availability evidence, and the same workflow-side MCP tool surface used by implementation, review, repair, and chat turns.\n\nEnable this plugin when a Syrus instance should offer Claude-backed automation. It can run alongside other agent-provider plugins so jobs and chats choose the appropriate provider per workflow.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/claude_agent.svg",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     true,
        category:        "agent",
        provides: {
          agent_provider: AgentProviders::Claude,
          chat_provider:  ChatProviders::Claude
        }
      )
    end
  end
end
