require "claude_agent/version"
require "claude_agent/engine"

module SyrusClaudeAgent
  def self.register!
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
    register_filter_chips!
    register_credential_probes!
  end

  def self.register_filter_chips!
    Filters.register_chip(
      subject: :admin_user,
      field: "has_claude_token",
      class_name: "Filters::Chips::AdminUsers::HasClaudeToken",
      after: "has_github_token"
    )
  end

  def self.register_credential_probes!
    CredentialProbe.register_probe("claude_oauth_token", ClaudeCredentialProbe)
  end
end
