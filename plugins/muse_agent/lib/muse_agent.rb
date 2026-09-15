module SyrusMuseAgent
  extend Syrus::PluginApi

  syrus_plugin "muse_agent" do
    display_name "Muse Agent"
    description "Runs workflow turns through Muse Code."
    long_description "Muse Agent connects Syrus workflows to Muse Code. It stores per-user Muse API keys, verifies the Muse CLI, launches workflow agent runs with isolated per-workflow Muse settings, and configures the Syrus MCP sidecar tools required by summary, review, test-plan, and visual-review steps."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/muse_agent.svg"
    author "Thomas Kadauke"
    category "agent_provider"
    default_enabled true
    disableable true
    provides agent_provider: "AgentProviders::Muse"

    while_enabled do |scope|
      scope.effect("credential probe") { CredentialProbe.register_probe("muse_api_key", MuseCredentialProbe) }
      scope.effect("secret extractor") { CredentialProbe.register_secret_extractor(MuseCredentialProbe::SECRET_EXTRACTOR) }
      scope.effect("admin user chips") do
        Filters.register_chips(
          subject: :admin_user,
          chips: { "has_muse_token" => "Filters::Chips::AdminUsers::HasMuseToken" }
        )
      end
    end
  end
end
