module SyrusCodexAgent
  extend Syrus::PluginApi

  syrus_plugin "codex_agent" do
    display_name "Codex Agent"
    description "Runs workflow and chat turns through Codex."
    long_description "Codex Agent connects Syrus workflows and chats to Codex. It provides the provider adapter used for implementation, review, repair, coding handoff, and interactive chat sessions, while feeding provider availability and failure classification back into Syrus' admission and retry systems.\n\nEnable this plugin when a Syrus instance should offer Codex-backed automation. It is independent from the Claude plugin, so operators can run either provider or both."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/codex_agent.svg"
    author "Thomas Kadauke"
    category "agent_provider"
    default_enabled true
    disableable true
    provides agent_provider: "AgentProviders::Codex",
             chat_provider: "ChatProviders::Codex"

    while_enabled do |scope|
      scope.effect("api key probe") { CredentialProbe.register_probe("codex_api_key", CodexCredentialProbe) }
      scope.effect("auth json probe") { CredentialProbe.register_probe("codex_auth_json", CodexCredentialProbe) }
      scope.effect("secret extractor") { CredentialProbe.register_secret_extractor(CodexCredentialProbe::SECRET_EXTRACTOR) }
      scope.effect("chat session rehydrator") { ChatSessionRehydrator.register("codex", ChatSessionRehydrator::Codex) }
      scope.effect("admin user chips") do
        Filters.register_chips(
          subject: :admin_user,
          chips: { "has_codex_token" => "Filters::Chips::AdminUsers::HasCodexToken" }
        )
      end
    end
  end
end
