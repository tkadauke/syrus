require "syrus/installer"

module SyrusClaudeAgent
  extend Syrus::PluginApi

  syrus_plugin "claude_agent" do
    experimental false
    requires_syrus nil
    display_name "Claude Agent"
    description "Runs workflow and chat turns through Claude."
    long_description "Claude Agent connects Syrus workflows and chats to the Claude CLI/provider adapter. It handles agent invocation, transcript capture, provider availability evidence, and the same workflow-side MCP tool surface used by implementation, review, repair, and chat turns.\n\nEnable this plugin when a Syrus instance should offer Claude-backed automation. It can run alongside other agent-provider plugins so jobs and chats choose the appropriate provider per workflow."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/claude_agent.svg"
    author "Thomas Kadauke"
    category "agent_provider"
    default_enabled false
    disableable true
    agent_runtime agent_provider: "AgentProviders::Claude",
                  chat_provider: "ChatProviders::Claude"
    toolkit credential_probes: { "claude_oauth_token" => "ClaudeCredentialProbe" },
            secret_extractors: [ "ClaudeCredentialProbe::SECRET_EXTRACTOR" ]
    surface filter_chips: { admin_user: { "has_claude_token" => "Filters::Chips::AdminUsers::HasClaudeToken" } }

    while_enabled do |scope|
      scope.effect("chat session rehydrator") { ChatSessionRehydrator.register("claude", ChatSessionRehydrator::Claude) }
    end
  end
end
