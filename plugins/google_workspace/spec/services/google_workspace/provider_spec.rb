require "rails_helper"
require Rails.root.join("plugins/connected_accounts/lib/connected_accounts/provider_test_kit").to_s

RSpec.describe GoogleWorkspace::Provider do
  let!(:config) do
    ConnectedAccounts::ProviderConfig.create!(provider_key: "google_workspace",
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth", token_url: "https://oauth2.googleapis.com/token",
      revoke_url: "https://oauth2.googleapis.com/revoke", identity_url: "https://www.googleapis.com/calendar/v3/calendars/primary",
      validate_url: "https://www.googleapis.com/calendar/v3/calendars/primary", client_id: "google-client", client_secret: "google-secret",
      scope_catalog: [ "calendar.read" ], read_only_scopes: [ "calendar.read" ], api_origins: [ "https://www.googleapis.com/calendar/v3/" ])
  end
  let(:manifest) { Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "google_workspace" } }
  let(:provider_declaration) do
    ConnectedAccounts::ProviderDeclaration.build(plugin_name: manifest.name,
      attributes: manifest.provides.fetch("connected_accounts:provider"))
  end
  let(:provider_class) { described_class }

  it_behaves_like "a connected accounts provider"

  it "builds a PKCE offline authorization URL with only the Calendar read-only scope" do
    result = described_class.authorization(ConnectedAccounts::Provider::AuthorizationContext.new(
      redirect_uri: "https://syrus.example/callback", state: "opaque", requested_scopes: [ "calendar.read" ], read_only: true,
      code_verifier: "verifier"
    ))
    query = Rack::Utils.parse_query(URI(result.fetch(:authorize_url)).query)

    expect(query).to include("access_type" => "offline", "prompt" => "consent", "code_challenge_method" => "S256",
      "scope" => GoogleWorkspace::Provider::GOOGLE_CALENDAR_SCOPE)
    expect(query["scope"]).not_to include("calendar.events")
  end

  it "exchanges a code and normalizes the provider scope without exposing the client secret" do
    stub = stub_request(:post, config.token_url).with { |request|
      params = Rack::Utils.parse_query(request.body)
      params["code"] == "code" && params["code_verifier"] == "verifier" && params["client_secret"] == "google-secret"
    }.to_return(status: 200, body: { access_token: "access-token", refresh_token: "refresh-token", expires_in: 3600,
      scope: described_class::GOOGLE_CALENDAR_SCOPE }.to_json)

    result = described_class.exchange_code(ConnectedAccounts::Provider::ExchangeCodeContext.new(
      code: "code", redirect_uri: "https://syrus.example/callback", code_verifier: "verifier"))

    expect(result).to include("access_token" => "access-token", "refresh_token" => "refresh-token", "scope" => "calendar.read")
    expect(stub).to have_been_requested
    expect(result.to_json).not_to include("google-secret")
  end

  it "refreshes while retaining the refresh token" do
    stub_request(:post, config.token_url).to_return(status: 200,
      body: { access_token: "new-access", expires_in: 3600, scope: described_class::GOOGLE_CALENDAR_SCOPE }.to_json)

    result = described_class.refresh(ConnectedAccounts::Provider::RefreshContext.new(tokens: { "refresh_token" => "refresh-token" }))

    expect(result).to include("access_token" => "new-access", "refresh_token" => "refresh-token", "scope" => "calendar.read")
  end

  it "revokes the refresh token" do
    request = stub_request(:post, config.revoke_url).with(body: { "token" => "refresh-token" }).to_return(status: 200)
    result = described_class.revoke(ConnectedAccounts::Provider::RevokeContext.new(tokens: { "refresh_token" => "refresh-token" }))
    expect(result).to eq(revoked: true)
    expect(request).to have_been_requested
  end

  it "uses the primary calendar id as the identity label and validates it" do
    stub_request(:get, config.identity_url).with(headers: { "Authorization" => "Bearer access-token" })
      .to_return(status: 200, body: { id: "person@example.test" }.to_json).times(2)

    expect(described_class.identity(ConnectedAccounts::Provider::IdentityContext.new(access_token: "access-token")))
      .to eq("label" => "person@example.test")
    expect(described_class.validate(ConnectedAccounts::Provider::ValidateContext.new(access_token: "access-token")))
      .to eq(healthy: true)
  end

  it "reports revoked validation as needing reauthorization without leaking the token" do
    stub_request(:get, config.identity_url).to_return(status: 401, body: { error: "invalid_token" }.to_json)
    result = described_class.validate(ConnectedAccounts::Provider::ValidateContext.new(access_token: "do-not-log-this"))
    expect(result).to eq(healthy: false, needs_reauth: true)
    expect(result.to_json).not_to include("do-not-log-this")
  end
end
