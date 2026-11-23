require "rails_helper"

RSpec.describe ConnectedAccounts::Account do
  let(:owner) { Factories.user }
  let(:credential) do
    CredentialStore::Credential.create!(
      name: "account-oauth",
      credential_type: "connected_accounts.oauth",
      scope_type: "user",
      scope_id: owner.id,
      created_by: owner,
      owner_user: owner,
      payload: { access_token: "access-secret", refresh_token: "refresh-secret" }.to_json,
      safe_metadata: {},
      target_constraints: { "allowed_url_prefixes" => [ "https://api.example.com/" ] },
      allowed_surfaces: [ "chat" ],
      allowed_tools: [ "connected_accounts.broker" ]
    )
  end

  def build_account(**attrs)
    described_class.new({
      provider: "example",
      display_label: "person@example.com",
      granted_scopes: %w[mail.read mail.send],
      status: "connected",
      read_only: false,
      acting_modes: %w[as_self],
      owner_user: owner,
      credential_store_credential: credential
    }.merge(attrs))
  end

  it "accepts every supported status" do
    described_class::STATUSES.each do |status|
      expect(build_account(status: status)).to be_valid
    end
  end

  it "rejects unknown statuses and acting modes" do
    account = build_account(status: "paused", acting_modes: %w[as_robot])

    expect(account).not_to be_valid
    expect(account.errors[:status]).to be_present
    expect(account.errors[:acting_modes]).to include("contains unsupported modes: as_robot")
  end

  it "limits a read-only account ceiling to read scopes" do
    account = build_account(read_only: true, granted_scopes: %w[calendar.readonly mail.read mail.send])

    expect(account.effective_scope_ceiling).to contain_exactly("calendar.readonly", "mail.read")
  end

  it "uses the full grant as the ceiling for a writable account" do
    account = build_account(read_only: false)

    expect(account.effective_scope_ceiling).to eq(%w[mail.read mail.send])
  end

  it "requires OAuth material pinned to the broker and provider origins" do
    credential.allowed_tools = [ "mail_plugin.direct" ]
    credential.target_constraints = {}
    account = build_account

    expect(account).not_to be_valid
    expect(account.errors[:credential_store_credential]).to include(
      "must be pinned to the connected account broker",
      "must be pinned to provider API origins"
    )
  end

  it "honors an explicit ceiling and requires it to stay within the grant" do
    account = build_account(scope_ceiling: %w[mail.read])
    invalid = build_account(scope_ceiling: %w[drive.read])

    expect(account.effective_scope_ceiling).to eq(%w[mail.read])
    expect(invalid).not_to be_valid
    expect(invalid.errors[:scope_ceiling]).to include("must be a subset of granted scopes")
  end

  it "requires instance accounts to have no user and only as_service access" do
    credential.assign_attributes(scope_type: "instance", scope_id: nil, owner_user: nil)
    credential.save!
    account = build_account(owner_kind: "instance", owner_user: nil, acting_modes: [ "as_service" ])

    expect(account).to be_valid
    account.acting_modes = [ "as_self" ]
    expect(account).not_to be_valid
    expect(account.errors[:acting_modes]).to include("must contain only as_service for an instance-owned account")
  end
end
