require "rails_helper"

RSpec.describe ConnectedAccounts::Disconnector do
  let(:user) { Factories.user }
  let(:credential) do
    CredentialStore::Credential.create!(name: "oauth", credential_type: "connected_accounts.oauth", scope_type: "user", scope_id: user.id,
      created_by: user, owner_user: user, payload: { access_token: "access-secret", refresh_token: "refresh-secret", expires_at: 1.hour.from_now.iso8601 }.to_json,
      safe_metadata: { "refreshable" => true }, target_constraints: { "allowed_url_prefixes" => [ "https://api.example/" ] }, allowed_tools: [ "connected_accounts.broker" ])
  end
  let(:account) do
    ConnectedAccounts::Account.create!(provider: "fake", display_label: "person@example.com", granted_scopes: [ "fake.read" ], status: "connected",
      read_only: true, scope_ceiling: [ "fake.read" ], acting_modes: [ "as_self" ], owner_user: user, credential_store_credential: credential)
  end

  it "revokes locally even when the provider fails, without auditing tokens" do
    declaration = instance_double(ConnectedAccounts::ProviderDeclaration)
    allow(declaration).to receive(:call).and_raise(StandardError, "provider failed near access-secret")
    allow(ConnectedAccounts::ProviderRegistry).to receive(:fetch).and_return(declaration)
    described_class.call(account: account, user: user)
    expect(account.reload).to be_revoked
    expect(credential.reload).to be_revoked
    event = credential.access_events.last
    expect(event.result).to eq("failed")
    expect(event.metadata.to_json).not_to include("access-secret", "refresh-secret")
  end
end
