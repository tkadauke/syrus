module SyrusAgyAgent
  extend Syrus::PluginApi

  syrus_plugin "agy_agent" do
    display_name "Antigravity Agent"
    description "Runs workflow and chat turns through Antigravity."
    long_description "Antigravity Agent connects Syrus workflows and chats to the agy CLI/provider adapter. It provides the provider core for Antigravity-backed implementation, review, repair, and interactive chat turns while keeping the invocation environment isolated from the worker account."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/agy_agent.svg"
    author "Thomas Kadauke"
    category "agent_provider"
    default_enabled true
    disableable true
    provides agent_provider: "AgentProviders::Agy",
             chat_provider: "ChatProviders::Agy"
    while_enabled do |scope|
      scope.effect("chat session rehydrator") { ChatSessionRehydrator.register("agy", ChatSessionRehydrator::Agy) }
    end
  end
end
