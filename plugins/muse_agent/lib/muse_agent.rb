module SyrusMuseAgent
  extend Syrus::PluginApi

  syrus_plugin "muse_agent" do
    display_name "Muse Agent"
    description "Runs workflow and chat turns through Muse Code."
    long_description "Muse Agent connects Syrus workflows and chats to Muse Code. Enable it from Admin -> Plugins after the worker/backend image includes the muse CLI and operators have saved per-user Muse API keys. The plugin verifies the Muse CLI separately from API credentials, launches agent runs with isolated Muse settings, configures Syrus MCP sidecar tools, captures resumable transcripts, and can be disabled live if upstream provider behavior changes."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/muse_agent.svg"
    author "Thomas Kadauke"
    category "agent_provider"
    default_enabled false
    disableable true
    provides agent_provider: "AgentProviders::Muse",
             chat_provider: "ChatProviders::Muse"

    while_enabled do |scope|
      scope.effect("credential probe") { CredentialProbe.register_probe("muse_api_key", MuseCredentialProbe) }
      scope.effect("secret extractor") { CredentialProbe.register_secret_extractor(MuseCredentialProbe::SECRET_EXTRACTOR) }
      scope.effect("chat session rehydrator") { ChatSessionRehydrator.register("muse", ChatSessionRehydrator::Muse) }
      scope.effect("admin user chips") do
        Filters.register_chips(
          subject: :admin_user,
          chips: { "has_muse_token" => "Filters::Chips::AdminUsers::HasMuseToken" }
        )
      end
    end
  end
end
