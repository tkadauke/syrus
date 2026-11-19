require "rails_helper"
require Rails.root.join("plugins/connected_accounts/lib/connected_accounts/provider_test_kit").to_s

RSpec.describe ConnectedAccounts::GenericOauth2Provider do
  let!(:config) do
    ConnectedAccounts::ProviderConfig.create!(provider_key: "generic_oauth2", authorize_url: "https://oauth.example/authorize",
      token_url: "https://oauth.example/token", revoke_url: "https://oauth.example/revoke", identity_url: "https://api.example/me",
      validate_url: "https://api.example/health", client_id: "client", client_secret: "secret", scope_catalog: %w[read write], api_origins: [ "https://api.example/" ])
  end
  let(:provider_declaration) do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "connected_accounts" }
    attributes = Array(manifest.provides.fetch("connected_accounts:provider")).find { |entry| entry[:key] == "generic_oauth2" }
    ConnectedAccounts::ProviderDeclaration.build(plugin_name: manifest.name, attributes: attributes)
  end
  let(:provider_class) { described_class }

  it_behaves_like "a connected accounts provider"

  it "builds PKCE authorization without exposing the client secret" do
    result = described_class.authorization(ConnectedAccounts::Provider::AuthorizationContext.new(
      redirect_uri: "https://syrus.example/callback", state: "opaque", requested_scopes: [ "read" ], read_only: true, code_verifier: "verifier"
    ))
    expect(result[:authorize_url]).to include("code_challenge_method=S256", "state=opaque")
    expect(result[:authorize_url]).not_to include("secret", "verifier")
  end

  it "classifies invalid grants as permanent without including response bodies" do
    response = instance_double(Net::HTTPBadRequest, code: "400", body: "access-token-secret")
    http = class_double(Net::HTTP)
    allow(http).to receive(:start).and_yield(instance_double(Net::HTTP, request: response))
    described_class.http = http
    expect {
      described_class.exchange_code(ConnectedAccounts::Provider::ExchangeCodeContext.new(code: "bad", redirect_uri: "https://syrus.example/callback", code_verifier: "verifier"))
    }.to raise_error(ConnectedAccounts::Provider::PermanentError, /HTTP 400/)
  ensure
    described_class.http = nil
  end
end
