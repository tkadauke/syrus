require "rails_helper"

RSpec.describe ProviderAccount do
  let(:user) { Factories.user }

  def create_account(**attributes)
    described_class.create!({
      user: user,
      provider_key: "claude",
      authentication_kind: "oauth_token",
      credential_payload: { "claude_oauth_token" => "oat-secret" },
      position: 0
    }.merge(attributes))
  end

  it "assigns a stable opaque public identifier and encrypts credentials at rest" do
    account = create_account
    stored = described_class.connection.select_value(
      "SELECT credential_payload FROM provider_accounts WHERE id = #{account.id}"
    )

    expect(account.public_id).to match(/\A[0-9a-f-]{36}\z/)
    expect(account.reload.credential_payload).to eq("claude_oauth_token" => "oat-secret")
    expect(stored).not_to include("oat-secret")
  end

  it "scopes labels to an owner's provider without using them as identifiers" do
    first = create_account(label: "Work")
    duplicate = described_class.new(
      user: user,
      provider_key: "claude",
      authentication_kind: "oauth_token",
      credential_payload: {},
      label: "work",
      position: 1
    )

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:label]).to be_present
    expect(first.public_id).not_to eq(first.label)
    expect(create_account(user: Factories.user, label: "Work").label).to eq("Work")
  end

  it "requires deterministic positions and positive optional weights" do
    create_account(position: 2)

    duplicate = described_class.new(
      user: user,
      provider_key: "claude",
      authentication_kind: "oauth_token",
      credential_payload: {},
      position: 2,
      weight: 0
    )

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:position]).to be_present
    expect(duplicate.errors[:weight]).to be_present
  end

  it "exposes enabled accounts in deterministic order and resolves the default" do
    default = create_account
    create_account(position: 2, label: "Later")
    create_account(position: 1, label: "Disabled", enabled: false)

    expect(user.default_provider_account("claude")).to eq(default)
    expect(user.enabled_provider_accounts("claude").pluck(:position)).to eq([ 0, 2 ])
  end

  it "keeps singular credential writes synchronized during the compatibility rollout" do
    user.update!(claude_oauth_token: "oat-one")

    account = user.default_provider_account("claude")
    expect(account.credential_payload).to eq("claude_oauth_token" => "oat-one")

    user.clear_credential!("claude_oauth_token")

    expect(user.provider_accounts.where(provider_key: "claude")).to be_empty
  end
end
