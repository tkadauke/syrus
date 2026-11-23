require "rails_helper"

RSpec.describe ConnectedAccounts::ProviderRegistry, :reset_plugin_registry do
  # connected_accounts hard-depends on credential_store; registered alone it is
  # degraded and, correctly, contributes nothing (NY18).
  around do |example|
    Syrus::PluginRegistry.reset!
    CredentialStore.register!
    ConnectedAccounts.register!
    AppSetting.current.update!(beta_mode_enabled: true)
    PluginRecord.find_by(name: "connected_accounts")&.update!(enabled: true)
    example.run
  ensure
    Syrus::PluginRegistry.reset!
    CredentialStore.register!
    ConnectedAccounts.register!
  end

  it "loads the fake provider from the hosted extension point" do
    expect(described_class.fetch("fake")).to have_attributes(
      provider: "ConnectedAccounts::FakeProvider", display_name: "Fake service", supports_read_only: true
    )
  end

  # Enabled is not enough: a contributor sitting on a missing dependency is
  # degraded, and its otherwise valid provider must not be offered (NY18).
  it "withholds a valid provider whose contributing plugin is unhealthy" do
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "unhealthy_accounts_provider", version: "1.0.0", depends_on: [ "missing_dependency" ],
      provides: { "connected_accounts:provider" => [ { provider: "ConnectedAccounts::FakeProvider", key: "unhealthy",
        display_name: "Unhealthy", capabilities: %w[authorization], callback_route: "/callback", supports_read_only: true,
        scopes: [ { key: "read", label: "Read", risk: "low", syrus_capabilities: [ "records.read@v1" ] } ] } ] }
    )

    keys = described_class.all.map(&:key)
    expect(keys).to include("fake")
    expect(keys).not_to include("unhealthy")
  end

  it "withholds a broken contribution and reports it in plugin health" do
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "broken_accounts_provider", version: "1.0.0",
      provides: {
        "connected_accounts:provider" => [
          {
            provider: "ConnectedAccounts::FakeProvider", key: "broken", display_name: "Broken",
            capabilities: %w[authorization], callback_route: "/callback", supports_read_only: false,
            scopes: [ { key: "read", label: "Read", risk: "low", syrus_capabilities: [ "records.read@v1" ] } ]
          }
        ]
      }
    )

    expect(described_class.all.map(&:key)).not_to include("broken")
    expect(Syrus::PluginRegistry.health.status("broken_accounts_provider")).to have_attributes(
      state: :degraded,
      reasons: include(a_string_including("missing required capabilities"))
    )
  end
end
