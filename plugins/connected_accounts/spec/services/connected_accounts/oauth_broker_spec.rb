require "rails_helper"

RSpec.describe ConnectedAccounts::OauthBroker do
  let(:user) { Factories.user }
  let!(:config) do
    ConnectedAccounts::ProviderConfig.create!(provider_key: "fake", authorize_url: "https://fake.example/authorize",
      token_url: "https://fake.example/token", identity_url: "https://fake.example/me", client_id: "client", client_secret: "secret",
      scope_catalog: %w[fake.read fake.write], api_origins: [ "https://api.fake.example/" ])
  end
  let(:declaration) do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "connected_accounts" }
    ConnectedAccounts::ProviderDeclaration.build(plugin_name: manifest.name,
      attributes: Array(manifest.provides.fetch("connected_accounts:provider")).find { |entry| entry[:key] == "fake" })
  end

  it "stores one constrained credential, honors the read-only ceiling, and rejects replay" do
    token, = ConnectedAccounts::OauthState.issue!(user: user, session_binding: "browser", provider: "fake",
      requested_scopes: %w[fake.read], read_only: true)
    allow(ConnectedAccounts::ProviderRegistry).to receive(:fetch).with("fake").and_return(declaration)

    account = described_class.complete!(provider: "fake", state: token, code: "one", user: user,
      session_binding: "browser", redirect_uri: "https://syrus.example/connected_accounts/callback/fake")
    expect(account).to have_attributes(granted_scopes: [ "fake.read" ], scope_ceiling: [ "fake.read" ], read_only: true)
    expect(JSON.parse(account.credential_store_credential.payload)).to include("access_token", "refresh_token", "expires_at")
    expect(account.credential_store_credential.target_constraints).to eq("allowed_url_prefixes" => [ "https://api.fake.example/" ])
    expect {
      described_class.complete!(provider: "fake", state: token, code: "two", user: user, session_binding: "browser",
        redirect_uri: "https://syrus.example/connected_accounts/callback/fake")
    }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
