require "syrus/installer"

module SyrusAgyAgent
  extend Syrus::Host::PluginApi

  syrus_plugin "agy_agent" do
    requires_syrus nil
    experimental true
    display_name "Antigravity Agent"
    description "Runs workflow and chat turns through Antigravity."
    long_description "Antigravity Agent connects Syrus workflows and chats to the agy CLI/provider adapter. It provides the provider core for Antigravity-backed implementation, review, repair, and interactive chat turns while keeping the invocation environment isolated from the worker account."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/agy_agent.svg"
    author "Thomas Kadauke"
    category "agent_provider"
    default_enabled false
    disableable true
    agent_runtime agent_provider: "AgentProviders::Agy",
                  chat_provider: "ChatProviders::Agy"
    toolkit credential_probes: { "agy" => "AgyCredentialProbe" },
            secret_extractors: [ "AgyCredentialProbe::SECRET_EXTRACTOR" ]
    while_enabled do |scope|
      scope.effect("chat session rehydrator") { Syrus::Host::ChatSessionRehydrator.register("agy", Syrus::Host::ChatSessionRehydrator::Agy) }
    end
  end
end
