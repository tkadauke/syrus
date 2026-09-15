module SyrusMuseAgent
  extend Syrus::PluginApi

  syrus_plugin "muse_agent" do
    display_name "Muse Agent"
    description "Stores and verifies Muse credentials without enabling workflow execution yet."
    long_description "Muse Agent is the initial integration shell for Muse Code. It adds the per-user API key credential and validates it through the Muse CLI, but intentionally does not register an agent or chat provider until the invocation and tool strategy is safe for Syrus workflows."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/muse_agent.svg"
    author "Thomas Kadauke"
    category "agent_provider"
    default_enabled true
    disableable true

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
