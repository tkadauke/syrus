require "syrus/installer"

module SyrusCodexAgent
  extend Syrus::PluginApi

  syrus_plugin "codex_agent" do
    experimental false
    requires_syrus nil
    display_name "Codex Agent"
    description "Runs workflow and chat turns through Codex."
    long_description "Codex Agent connects Syrus workflows and chats to Codex. It provides the provider adapter used for implementation, review, repair, coding handoff, and interactive chat sessions, while feeding provider availability and failure classification back into Syrus' admission and retry systems.\n\nEnable this plugin when a Syrus instance should offer Codex-backed automation. It is independent from the Claude plugin, so operators can run either provider or both."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/codex_agent.svg"
    author "Thomas Kadauke"
    category "agent_provider"
    default_enabled false
    disableable true
    agent_runtime agent_provider: "AgentProviders::Codex",
                  chat_provider: "ChatProviders::Codex"
    toolkit credential_probes: {
      "codex_api_key" => "CodexCredentialProbe",
      "codex_auth_json" => "CodexCredentialProbe"
    }, secret_extractors: [ "CodexCredentialProbe::SECRET_EXTRACTOR" ]
    surface filter_chips: { admin_user: { "has_codex_token" => "Filters::Chips::AdminUsers::HasCodexToken" } }

    while_enabled do |scope|
      scope.effect("chat session rehydrator") { Syrus::Host::ChatSessionRehydrator.register("codex", Syrus::Host::ChatSessionRehydrator::Codex) }
    end
  end
end
