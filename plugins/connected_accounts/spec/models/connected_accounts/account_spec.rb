require "rails_helper"

RSpec.describe ConnectedAccounts::Account do
  let(:owner) { Factories.user }
  let(:credential) do
    CredentialStore::Credential.create!(
      name: "example-oauth", credential_type: "connected_accounts.oauth",
      scope_type: "user", scope_id: owner.id, created_by: owner, owner_user: owner,
      payload: { access_token: "access-secret", refresh_token: "refresh-secret" }.to_json,
      allowed_tools: [ ConnectedAccounts::AccountClient::TOOL_NAME ],
      target_constraints: { "allowed_url_prefixes" => [ "https://api.example.com/" ] }
    )
  end

  def account(**attrs)
    described_class.new({
      owner_user: owner, credential:, provider_key: "example", display_label: "owner@example.com",
      granted_scopes: %w[mail.read mail.send], scope_ceiling: [ "mail.read" ],
      acting_modes: %w[as_self], status: "connected"
    }.merge(attrs))
  end

  it "accepts every supported status" do
    described_class::STATUSES.each { |status| expect(account(status:)).to be_valid }
  end

  it "rejects unsupported statuses" do
    expect(account(status: "pending")).not_to be_valid
  end

  it "enforces the scope ceiling independently of the provider grant" do
    record = account

    expect(record.permits_scopes?(%w[mail.read])).to be(true)
    expect(record.permits_scopes?(%w[mail.send])).to be(false)
    expect(account(scope_ceiling: %w[mail.admin])).not_to be_valid
  end

  it "validates acting-mode eligibility" do
    record = account

    expect(record.permits_acting_mode?(:as_self)).to be(true)
    expect(record.permits_acting_mode?(:as_owner)).to be(false)
    expect(account(acting_modes: %w[impersonate])).not_to be_valid
  end

  it "requires an owner-matched OAuth credential pinned to AccountClient and provider origins" do
    credential.allowed_tools = [ "mail.direct" ]
    expect(account).not_to be_valid

    credential.allowed_tools = [ ConnectedAccounts::AccountClient::TOOL_NAME ]
    credential.target_constraints = {}
    expect(account).not_to be_valid
  end
end
