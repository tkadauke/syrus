require "rails_helper"

RSpec.describe ConnectedAccounts::Account do
  let(:user) { Factories.user }

  def credential(owner: user, **attrs)
    CredentialStore::Credential.create!({
      name: "connected-oauth-#{SecureRandom.hex(3)}",
      credential_type: "connected_accounts.oauth",
      scope_type: "user",
      scope_id: owner.id,
      created_by: owner,
      owner_user: owner,
      payload: { access_token: "access-secret", refresh_token: "refresh-secret" }.to_json,
      target_constraints: { "allowed_url_prefixes" => [ "https://api.example.com/" ] },
      allowed_surfaces: [ "workflow", "chat" ],
      allowed_tools: [ ConnectedAccounts::AccountClient::BROKER_TOOL_NAME ]
    }.merge(attrs))
  end

  def account(**attrs)
    described_class.new({
      provider_key: "example",
      display_label: "person@example.com",
      granted_scopes: %w[mail.read mail.write],
      access_ceiling: [ "mail.read" ],
      acting_modes: %w[as_self as_service],
      status: "connected",
      owner_user: user,
      credential: credential
    }.merge(attrs))
  end

  it "accepts every account lifecycle status" do
    described_class::STATUSES.each do |status|
      expect(account(status: status)).to be_valid
    end
  end

  it "rejects unknown statuses" do
    record = account(status: "paused")

    expect(record).not_to be_valid
    expect(record.errors[:status]).to be_present
  end

  it "enforces the scope ceiling independently of the provider grant" do
    record = account

    expect(record.permits_scopes?(%w[mail.read])).to be(true)
    expect(record.permits_scopes?(%w[mail.write])).to be(false)
  end

  it "requires the ceiling to be a subset of granted scopes" do
    record = account(access_ceiling: [ "calendar.write" ])

    expect(record).not_to be_valid
    expect(record.errors[:access_ceiling]).to include("must be a subset of granted scopes")
  end

  it "validates acting-mode eligibility" do
    record = account

    expect(record.permits_acting_mode?(:as_self)).to be(true)
    expect(record.permits_acting_mode?(:as_owner)).to be(false)
  end

  it "requires credentials to be pinned to the broker and provider API origins" do
    unpinned = credential(allowed_tools: [ "another_plugin.mail" ], target_constraints: {})
    record = account(credential: unpinned)

    expect(record).not_to be_valid
    expect(record.errors[:credential]).to include("must be pinned to the account broker")
    expect(record.errors[:credential]).to include("must declare provider API origins")
  end
end
