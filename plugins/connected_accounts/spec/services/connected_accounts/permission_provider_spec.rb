require "rails_helper"

RSpec.describe ConnectedAccounts::PermissionProvider do
  let(:owner) { Factories.user }
  let(:credential) do
    CredentialStore::Credential.create!(name: "permission-account", credential_type: "connected_accounts.oauth",
      scope_type: "user", scope_id: owner.id, created_by: owner, owner_user: owner,
      payload: { access_token: "secret" }.to_json, safe_metadata: {},
      target_constraints: { "allowed_url_prefixes" => [ "https://api.example/" ] },
      allowed_tools: [ "connected_accounts.broker" ])
  end
  let!(:account) do
    ConnectedAccounts::Account.create!(provider: "example", display_label: "Visible account", granted_scopes: [ "mail.read" ],
      status: "connected", read_only: true, acting_modes: [ "as_self" ], owner_user: owner,
      credential_store_credential: credential)
  end

  it "normalizes, labels, and validates typed account scopes" do
    schema = described_class.permission_resource_scopes.fetch(:connected_account)
    scope = { account_id: account.id.to_s, acting_mode: "as_self", sub_resources: { mailbox: "inbox" } }

    expect(schema.normalize(scope, context: { user: owner }).value).to eq(
      "account_id" => account.id, "acting_mode" => "as_self", "sub_resources" => { "mailbox" => "inbox" })
    expect(schema.label(scope, context: { user: owner }).value).to eq("Visible account (as self)")
    expect(schema.validate(scope, context: { user: owner })).to be_success
  end

  it "returns the same non-disclosing answers for unknown and hidden accounts" do
    schema = described_class.permission_resource_scopes.fetch(:connected_account)
    stranger = Factories.user

    expect(schema.lookup(account.id, context: { user: stranger })).to have_attributes(status: :not_found)
    expect(schema.lookup(-1, context: { user: stranger })).to have_attributes(status: :not_found)
    hidden = schema.validate({ account_id: account.id, acting_mode: "as_self" }, context: { user: stranger })
    unknown = schema.validate({ account_id: -1, acting_mode: "as_self" }, context: { user: stranger })
    expect(hidden.errors).to eq(unknown.errors)
  end

  it "lists only the current user's accounts as safe authoring choices" do
    stranger = Factories.user
    hidden_credential = CredentialStore::Credential.create!(name: "hidden-permission-account",
      credential_type: "connected_accounts.oauth", scope_type: "user", scope_id: stranger.id,
      created_by: stranger, owner_user: stranger, payload: { access_token: "hidden" }.to_json,
      safe_metadata: {}, target_constraints: { "allowed_url_prefixes" => [ "https://api.example/" ] },
      allowed_tools: [ "connected_accounts.broker" ])
    ConnectedAccounts::Account.create!(provider: "example", display_label: "Hidden account", granted_scopes: [ "mail.read" ],
      status: "connected", read_only: true, acting_modes: [ "as_self" ], owner_user: stranger,
      credential_store_credential: hidden_credential)

    options = described_class.permission_resource_scopes.fetch(:connected_account)
      .authoring_options(context: { user: owner })
    account_field = options.fetch("fields").find { |field| field.fetch("name") == "account_id" }

    expect(account_field.fetch("type")).to eq("select")
    expect(account_field.fetch("choices")).to eq([ { "label" => "Visible account", "value" => account.id.to_s } ])
  end
end
