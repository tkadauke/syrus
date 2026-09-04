module SyrusClaudeAgent
  extend Syrus::PluginApi

  syrus_plugin "claude_agent" do
    display_name "Claude Agent"
    description "Runs workflow and chat turns through Claude."
    long_description "Claude Agent connects Syrus workflows and chats to the Claude CLI/provider adapter. It handles agent invocation, transcript capture, provider availability evidence, and the same workflow-side MCP tool surface used by implementation, review, repair, and chat turns.\n\nEnable this plugin when a Syrus instance should offer Claude-backed automation. It can run alongside other agent-provider plugins so jobs and chats choose the appropriate provider per workflow."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/claude_agent.svg"
    author "Thomas Kadauke"
    category "agent_provider"
    default_enabled true
    disableable true
    provides agent_provider: "AgentProviders::Claude",
             chat_provider: "ChatProviders::Claude"

    while_enabled do |scope|
      scope.effect("credential probe") { CredentialProbe.register_probe("claude_oauth_token", ClaudeCredentialProbe) }
      scope.effect("secret extractor") { CredentialProbe.register_secret_extractor(ClaudeCredentialProbe::SECRET_EXTRACTOR) }
      scope.effect("chat session rehydrator") { ChatSessionRehydrator.register("claude", ChatSessionRehydrator::Claude) }
      scope.effect("admin user chips") do
        Filters.register_chips(
          subject: :admin_user,
          chips: { "has_claude_token" => "Filters::Chips::AdminUsers::HasClaudeToken" }
        )
      end
    end
  end
end
