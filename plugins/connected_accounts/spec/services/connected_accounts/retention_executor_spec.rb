require "rails_helper"

RSpec.describe ConnectedAccounts::RetentionExecutor do
  it "purges expired disconnected accounts, audit history, and encrypted credentials" do
    user = Factories.user
    credential = CredentialStore::Credential.create!(name: "retained-account", credential_type: "connected_accounts.oauth",
      scope_type: "user", scope_id: user.id, created_by: user, owner_user: user,
      payload: { access_token: "secret" }.to_json, safe_metadata: {},
      target_constraints: { "allowed_url_prefixes" => [ "https://api.example/" ] },
      allowed_tools: [ "connected_accounts.broker" ], revoked_at: 40.days.ago)
    account = ConnectedAccounts::Account.create!(provider: "example", display_label: "Expired account",
      granted_scopes: [ "mail.read" ], status: "revoked", read_only: true, acting_modes: [ "as_self" ],
      owner_user: user, credential_store_credential: credential)
    account.update_columns(updated_at: 40.days.ago)
    audit = CredentialStore::CredentialAccessEvent.record!(credential: credential, user: user, surface: "api",
      action: "revoke", result: "allowed", tool_name: "connected_accounts.broker")
    definition = instance_double(RetentionPolicyRegistry::Definition, retention_window: 30.days)

    result = described_class.new(definition).call

    expect(result).to have_attributes(deleted_count: 3, backlog: false)
    expect(ConnectedAccounts::Account.where(id: account.id)).not_to exist
    expect(CredentialStore::CredentialAccessEvent.where(id: audit.id)).not_to exist
    expect(CredentialStore::Credential.where(id: credential.id)).not_to exist
  end
end
