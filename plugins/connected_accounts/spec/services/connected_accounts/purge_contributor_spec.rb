require "rails_helper"

RSpec.describe ConnectedAccounts::PurgeContributor do
  it "reports and removes audit rows and encrypted credentials held outside plugin tables" do
    user = Factories.user
    credential = CredentialStore::Credential.create!(name: "purged-account", credential_type: "connected_accounts.oauth",
      scope_type: "user", scope_id: user.id, created_by: user, owner_user: user,
      payload: { access_token: "secret" }.to_json, safe_metadata: {},
      target_constraints: { "allowed_url_prefixes" => [ "https://api.example/" ] },
      allowed_tools: [ "connected_accounts.broker" ])
    ConnectedAccounts::Account.create!(provider: "example", display_label: "Purged account",
      granted_scopes: [ "mail.read" ], status: "connected", read_only: true, acting_modes: [ "as_self" ],
      owner_user: user, credential_store_credential: credential)
    audit = CredentialStore::CredentialAccessEvent.record!(credential: credential, user: user, surface: "api",
      action: "create", result: "allowed", tool_name: "connected_accounts.broker")

    expect(described_class.purge_report("connected_accounts")).to contain_exactly(
      "1 connected-account credential audit rows", "1 connected-account encrypted credentials")
    expect(described_class.purge!("connected_accounts")).to contain_exactly(
      "1 connected-account credential audit rows", "1 connected-account encrypted credentials")
    expect(CredentialStore::CredentialAccessEvent.where(id: audit.id)).not_to exist
    expect(CredentialStore::Credential.where(id: credential.id)).not_to exist
    expect(described_class.purge!("another_plugin")).to eq([])
  end
end
