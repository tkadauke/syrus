require "rails_helper"

RSpec.describe ConnectedAccounts::TokenMaintenance do
  let(:user) { Factories.user }
  let(:credential) do
    CredentialStore::Credential.create!(name: "oauth-maintenance", credential_type: "connected_accounts.oauth", scope_type: "user", scope_id: user.id,
      created_by: user, owner_user: user, payload: { access_token: "old-secret", refresh_token: "refresh-secret", expires_at: 1.minute.from_now.iso8601 }.to_json,
      safe_metadata: { "refreshable" => true }, target_constraints: { "allowed_url_prefixes" => [ "https://api.example/" ] }, allowed_tools: [ "connected_accounts.broker" ])
  end
  let(:account) do
    ConnectedAccounts::Account.create!(provider: "fake", display_label: "person@example.com", granted_scopes: [ "fake.read" ], status: "connected",
      read_only: true, scope_ceiling: [ "fake.read" ], acting_modes: [ "as_self" ], owner_user: user, credential_store_credential: credential)
  end
  let(:declaration) { instance_double(ConnectedAccounts::ProviderDeclaration) }

  before { allow(ConnectedAccounts::ProviderRegistry).to receive(:fetch).and_return(declaration) }

  it "refreshes under the credential broker and records its dedicated audit action" do
    allow(declaration).to receive(:call).with("refresh", anything).and_return(access_token: "new-secret", expires_in: 3600)
    allow(declaration).to receive(:call).with("validate", anything).and_return(healthy: true)
    described_class.call(account)
    expect(JSON.parse(credential.reload.payload)["access_token"]).to eq("new-secret")
    expect(credential.access_events.where(action: "refresh", result: "allowed")).to exist
  end

  it "moves permanently invalid refresh authorization to needs_reauth" do
    allow(declaration).to receive(:call).with("refresh", anything).and_raise(ConnectedAccounts::Provider::PermanentError, "invalid grant")
    described_class.call(account)
    expect(account.reload).to be_needs_reauth
  end

  it "lets transient failures reach Active Job's bounded retry policy" do
    allow(declaration).to receive(:call).with("refresh", anything).and_raise(ConnectedAccounts::Provider::TransientError, "try later")
    expect { described_class.call(account) }.to raise_error(ConnectedAccounts::Provider::TransientError, "try later")
  end

  it "validates a non-expiring provider token without trying to refresh it" do
    credential.update!(payload: { access_token: "static-secret" }.to_json, safe_metadata: { "refreshable" => false })
    expect(declaration).not_to receive(:call).with("refresh", anything)
    expect(declaration).to receive(:call).with("validate", anything).and_return(healthy: true)

    described_class.call(account)

    expect(account.reload).to be_connected
  end
end
