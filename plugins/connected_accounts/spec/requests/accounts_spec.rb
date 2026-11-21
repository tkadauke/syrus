require "rails_helper"

RSpec.describe "Connected account settings", type: :request do
  let(:user) { Factories.user }
  let(:credential) do
    CredentialStore::Credential.create!(name: "settings-account", credential_type: "connected_accounts.oauth",
      scope_type: "user", scope_id: user.id, created_by: user, owner_user: user, payload: { access_token: "secret" }.to_json,
      safe_metadata: {}, target_constraints: { "allowed_url_prefixes" => [ "https://api.example/" ] },
      allowed_tools: [ "connected_accounts.broker" ])
  end
  let!(:account) do
    ConnectedAccounts::Account.create!(provider: "fake", display_label: "person@example.com",
      granted_scopes: %w[fake.read fake.write], status: "connected", read_only: false, acting_modes: [ "as_self" ],
      owner_user: user, credential_store_credential: credential)
  end

  before do
    PluginRecord.find_by!(name: "connected_accounts").update!(enabled: true)
    sign_in_as(user)
  end

  it "lists only the signed-in user's accounts with management details" do
    get "/api/v1/app/connected_accounts/accounts"

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("accounts").first).to include(
      "display_label" => "person@example.com", "granted_scopes" => %w[fake.read fake.write],
      "status" => "connected", "read_only" => false, "last_used_at" => nil)
  end

  it "applies the provider's safe read-only ceiling" do
    patch "/api/v1/app/connected_accounts/accounts/#{account.id}", params: { account: { read_only: true } }, as: :json

    expect(response).to have_http_status(:ok)
    expect(account.reload).to have_attributes(read_only: true, scope_ceiling: [ "fake.read" ])
  end

  it "does not disclose another user's account" do
    sign_in_as(Factories.user)
    patch "/api/v1/app/connected_accounts/accounts/#{account.id}", params: { account: { read_only: true } }, as: :json

    expect(response).to have_http_status(:not_found)
  end
end
