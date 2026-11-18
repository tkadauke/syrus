require "rails_helper"

RSpec.describe "Connected Accounts OAuth lifecycle" do
  let(:user) { Factories.user(admin: true) }
  let(:client_credential) do
    ConnectedAccounts::CredentialMaterial.store_client!(user: user, key: "example",
      client_id: "client-id", client_secret: "super-secret-client-value")
  end
  let!(:config) do
    ConnectedAccounts::ProviderConfig.create!(key: "example", display_name: "Example",
      authorize_url: "https://oauth.example/authorize", token_url: "https://oauth.example/token",
      revoke_url: "https://oauth.example/revoke", identity_url: "https://api.example/me",
      scopes: %w[records.read], api_origins: [ "https://api.example/" ],
      credential_store_credential: client_credential, created_by: user)
  end

  def start_flow
    ConnectedAccounts::OauthFlow.start!(provider: "example", user: user,
      redirect_uri: "https://syrus.example/api/v1/app/connected_accounts/callback/example",
      scopes: %w[records.read])
  end

  def state_from(url)
    Rack::Utils.parse_query(URI.parse(url).query).fetch("state")
  end

  before do
    stub_request(:post, "https://oauth.example/token").to_return(status: 200,
      body: { access_token: "access-secret", refresh_token: "refresh-secret", expires_in: 3600 }.to_json)
    stub_request(:get, "https://api.example/me").with(headers: { "Authorization" => "Bearer access-secret" })
      .to_return(status: 200, body: { email: "person@example.com" }.to_json)
  end

  it "authorizes with state and PKCE, exchanges once, and stores encrypted broker material" do
    url = start_flow
    query = Rack::Utils.parse_query(URI.parse(url).query)
    expect(query).to include("client_id" => "client-id", "code_challenge_method" => "S256")
    expect(query.fetch("code_challenge")).to be_present

    account = ConnectedAccounts::OauthFlow.complete!(state: query.fetch("state"), code: "code-1")
    expect(account).to have_attributes(display_label: "person@example.com", status: "connected")
    expect(account.credential_store_credential.payload).to include("access-secret", "refresh-secret")

    expect { ConnectedAccounts::OauthFlow.complete!(state: query.fetch("state"), code: "code-1") }
      .to raise_error(ConnectedAccounts::OauthFlow::InvalidState)
  end

  it "rolls back credential material when account creation fails" do
    state = state_from(start_flow)
    credential_count = CredentialStore::Credential.count
    allow(ConnectedAccounts::Account).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

    expect { ConnectedAccounts::OauthFlow.complete!(state: state, code: "code-1") }
      .to raise_error(ActiveRecord::RecordInvalid)
    expect(CredentialStore::Credential.count).to eq(credential_count)
  end

  it "rejects a mismatched state without contacting the token endpoint" do
    start_flow
    expect { ConnectedAccounts::OauthFlow.complete!(state: "wrong", code: "code-1") }
      .to raise_error(ConnectedAccounts::OauthFlow::InvalidState)
    expect(a_request(:post, "https://oauth.example/token")).not_to have_been_made
  end

  it "refreshes through the provider and updates expiry" do
    account = ConnectedAccounts::OauthFlow.complete!(state: state_from(start_flow), code: "code-1")
    stub_request(:post, "https://oauth.example/token").to_return(status: 200,
      body: { access_token: "new-access", expires_in: 7200 }.to_json)

    ConnectedAccounts::RefreshJob.perform_now(account.id)

    expect(JSON.parse(account.credential_store_credential.reload.payload)).to include(
      "access_token" => "new-access", "refresh_token" => "refresh-secret")
    expect(account.reload).to be_connected
  end

  it "marks refresh failures for reauthorization and creates one inbox notification" do
    account = ConnectedAccounts::OauthFlow.complete!(state: state_from(start_flow), code: "code-1")
    stub_request(:post, "https://oauth.example/token").to_return(status: 401, body: "denied")

    ConnectedAccounts::RefreshJob.perform_now(account.id)

    expect(account.reload).to be_needs_reauth
    expect(Notification.where(user: user, dedupe_key: "connected-account-reauth-#{account.id}").count).to eq(1)
  end

  it "re-raises refresh rate limits without requiring reauthorization" do
    account = ConnectedAccounts::OauthFlow.complete!(state: state_from(start_flow), code: "code-1")
    stub_request(:post, "https://oauth.example/token").to_return(status: 429,
      headers: { "Retry-After" => "45" }, body: "temporarily limited")

    expect { ConnectedAccounts::RefreshJob.perform_now(account.id) }
      .to raise_error(ConnectedAccounts::Problem) { |error| expect(error.retry_after).to eq(45) }
    expect(account.reload).to be_connected
    expect(Notification.where(user: user, dedupe_key: "connected-account-reauth-#{account.id}")).to be_empty
  end

  it "revokes remotely, erases token material, retains account history, and marks it revoked" do
    account = ConnectedAccounts::OauthFlow.complete!(state: state_from(start_flow), code: "code-1")
    stub_request(:post, "https://oauth.example/revoke").to_return(status: 200, body: "{}")

    ConnectedAccounts::Disconnector.call(account: account, user: user)

    expect(account.reload).to be_revoked
    expect(account.credential_store_credential.reload.payload).to eq({ revoked: true }.to_json)
    expect(account.credential_store_credential).to be_revoked
  end

  it "rolls back credential erasure when the revoked status cannot be persisted" do
    account = ConnectedAccounts::OauthFlow.complete!(state: state_from(start_flow), code: "code-1")
    original_payload = account.credential_store_credential.payload
    stub_request(:post, "https://oauth.example/revoke").to_return(status: 200, body: "{}")
    allow(account).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

    expect { ConnectedAccounts::Disconnector.call(account: account, user: user) }
      .to raise_error(ActiveRecord::RecordInvalid)
    expect(account.credential_store_credential.reload.payload).to eq(original_payload)
    expect(account.reload).to be_connected
  end

  it "updates health status and exposes rate limit retry-after without leaking response bodies" do
    account = ConnectedAccounts::OauthFlow.complete!(state: state_from(start_flow), code: "code-1")
    stub_request(:get, "https://api.example/me").to_return(status: 200, body: { email: "ok@example.com" }.to_json)
    ConnectedAccounts::HealthProbeJob.perform_now(account.id)
    expect(account.reload).to be_connected

    stub_request(:get, "https://api.example/me").to_return(status: 429,
      headers: { "Retry-After" => "45" }, body: "access-secret server-debug")
    expect { ConnectedAccounts::HealthProbeJob.perform_now(account.id) }
      .to raise_error(ConnectedAccounts::Problem) { |error| expect(error.as_json).to eq(code: "rate_limited", message: "OAuth provider rate limit reached", retry_after: 45) }
  end
end
