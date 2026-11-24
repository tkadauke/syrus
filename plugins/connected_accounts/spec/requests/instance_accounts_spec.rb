require "rails_helper"

RSpec.describe "Connected account instance tokens", type: :request do
  let(:admin) { Factories.user(global_role: "admin") }
  let(:declaration) do
    ConnectedAccounts::ProviderDeclaration.build(plugin_name: "example_plugin", attributes: {
      provider: "ConnectedAccounts::FakeProvider", key: "token_example", display_name: "Token example",
      authorization_kind: "token", system_service_identities: [ "platform.delivery" ],
      capabilities: ConnectedAccounts::Provider::REQUIRED_CAPABILITIES,
      callback_route: "/unused", supports_read_only: false,
      scopes: [ { key: "messages.send", label: "Send messages", risk: "high", syrus_capabilities: [ "messages.send@v1" ] } ]
    })
  end

  before do
    PluginRecord.find_by!(name: "connected_accounts").update!(enabled: true)
    allow(ConnectedAccounts::ProviderRegistry).to receive(:all).and_return([ declaration ])
    allow(ConnectedAccounts::ProviderRegistry).to receive(:fetch).with("token_example").and_return(declaration)
    ConnectedAccounts::ProviderConfig.create!(provider_key: "token_example", authorize_url: "https://example.test/auth",
      token_url: "https://example.test/token", identity_url: "https://example.test/me", client_id: "unused",
      client_secret: "unused", scope_catalog: [ "messages.send" ], read_only_scopes: [],
      api_origins: [ "https://api.example.test/" ])
    sign_in_as(admin)
  end

  it "stores a validated token once, rotates it, and disconnects it without disclosure" do
    post "/api/v1/app/admin/connected_accounts/instance_accounts", params: {
      account: { provider: "token_example", token: "first-secret-token", display_label: "Delivery bot" }
    }, as: :json
    expect(response).to have_http_status(:created), response.body
    expect(response.body).not_to include("first-secret-token")
    account = ConnectedAccounts::Account.find(response.parsed_body.dig("account", "id"))
    expect(account).to have_attributes(owner_kind: "instance", owner_user_id: nil, acting_modes: [ "as_service" ])
    first_credential = account.credential_store_credential

    post "/api/v1/app/admin/connected_accounts/instance_accounts", params: {
      account: { provider: "token_example", token: "second-secret-token", display_label: "Delivery bot" }
    }, as: :json
    expect(response.body).not_to include("second-secret-token")
    expect(first_credential.reload).to be_revoked
    expect(account.reload.credential_store_credential.access_events.where(action: "rotate", result: "allowed")).to exist
    expect(account.credential_store_credential.access_events.map(&:attributes).to_s).not_to include("second-secret-token")

    delete "/api/v1/app/admin/connected_accounts/instance_accounts/#{account.id}"
    expect(response).to have_http_status(:ok)
    expect(account.reload).to be_revoked
  end

  it "pins a manifest-declared API origin and derives the label from the provider's identity" do
    declared = ConnectedAccounts::ProviderDeclaration.build(plugin_name: "example_plugin", attributes: {
      provider: "ConnectedAccounts::FakeProvider", key: "declared_origin", display_name: "Declared origin",
      authorization_kind: "token", capabilities: ConnectedAccounts::Provider::REQUIRED_CAPABILITIES,
      callback_route: "/unused", supports_read_only: false,
      configuration: { api_origins: [ "https://api.declared.test/v1/" ] },
      scopes: [ { key: "messages.send", label: "Send messages", risk: "high", syrus_capabilities: [ "messages.send@v1" ] } ]
    })
    allow(ConnectedAccounts::ProviderRegistry).to receive(:all).and_return([ declared ])
    allow(ConnectedAccounts::ProviderRegistry).to receive(:fetch).with("declared_origin").and_return(declared)
    allow(ConnectedAccounts::FakeProvider).to receive(:identity).and_return(label: "the-bot")

    account = ConnectedAccounts::TokenBroker.connect!(provider: "declared_origin", token: "declared-secret-token", label: nil, admin: admin)

    expect(account.display_label).to eq("the-bot")
    expect(account.credential_store_credential.target_constraints).to eq("allowed_url_prefixes" => [ "https://api.declared.test/v1/" ])
    expect(ConnectedAccounts::TokenBroker.instance_account("declared_origin")).to eq(account)
  end

  it "rejects validation failures without leaking the submitted token" do
    allow(ConnectedAccounts::FakeProvider).to receive(:validate).and_return(healthy: false, message: "bad token-secret-value")
    post "/api/v1/app/admin/connected_accounts/instance_accounts", params: {
      account: { provider: "token_example", token: "token-secret-value" }
    }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).not_to include("token-secret-value")
  end

  it "is forbidden to non-administrators" do
    sign_in_as(Factories.user)
    get "/api/v1/app/admin/connected_accounts/instance_accounts"
    expect(response).to have_http_status(:forbidden)
  end
end
