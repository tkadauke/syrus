require "rails_helper"

RSpec.describe ConnectedAccounts::FakeProvider do
  let(:declaration) do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "connected_accounts" }
    attributes = Array(manifest.provides.fetch("connected_accounts:provider")).first
    ConnectedAccounts::ProviderDeclaration.build(plugin_name: manifest.name, attributes: attributes)
  end

  it "builds an authorization URL from its context and manifest scopes" do
    result = declaration.call("authorization", ConnectedAccounts::Provider::AuthorizationContext.new(
      redirect_uri: "https://syrus.example/callback", state: "state-123",
      requested_scopes: %w[fake.read], read_only: true
    ))

    uri = URI.parse(result.fetch(:authorize_url))
    expect(uri.host).to eq("fake.example")
    expect(Rack::Utils.parse_query(uri.query)).to include(
      "redirect_uri" => "https://syrus.example/callback",
      "state" => "state-123", "scope" => "fake.read", "read_only" => "true"
    )
  end

  it "exchanges and refreshes tokens" do
    exchanged = declaration.call("exchange_code", ConnectedAccounts::Provider::ExchangeCodeContext.new(
      code: "code-1", redirect_uri: "https://syrus.example/callback"
    ))
    refreshed = declaration.call("refresh", ConnectedAccounts::Provider::RefreshContext.new(tokens: exchanged))

    expect(exchanged).to include(access_token: "fake-access-code-1", refresh_token: "fake-refresh-code-1")
    expect(refreshed).to include(access_token: "fake-access-refreshed", refresh_token: "fake-refresh-code-1")
  end

  it "revokes tokens and resolves an identity label" do
    expect(declaration.call("revoke", ConnectedAccounts::Provider::RevokeContext.new(tokens: { access_token: "token" })))
      .to eq(revoked: true)
    expect(declaration.call("identity", ConnectedAccounts::Provider::IdentityContext.new(access_token: "person")))
      .to eq(label: "person@fake.example")
  end

  it "validates account health" do
    expect(declaration.call("validate", ConnectedAccounts::Provider::ValidateContext.new(access_token: "token")))
      .to eq(healthy: true, message: "ok")
    expect(declaration.call("validate", ConnectedAccounts::Provider::ValidateContext.new(access_token: nil)))
      .to eq(healthy: false, message: "missing access token")
  end

  it "verifies and normalizes inbound events" do
    context = ConnectedAccounts::Provider::EventsContext.new(
      headers: { "X-Fake-Signature" => "valid" },
      body: { id: "event-1", type: "record.changed", data: { record_id: 7 } }.to_json
    )

    expect(declaration.call("events", context)).to eq(
      event_id: "event-1", event_type: "record.changed", data: { "record_id" => 7 }
    )
    expect {
      declaration.call("events", context.with(headers: {}))
    }.to raise_error(ArgumentError, "invalid fake event signature")
  end
end
