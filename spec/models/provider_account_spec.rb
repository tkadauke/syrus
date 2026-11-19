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

  it "pins workflow, run, and captured session provenance to one account" do
    user.update!(claude_oauth_token: "legacy-token")
    account = user.default_provider_account("claude")
    job = Factories.job(repository: Factories.repository(user: user), agent_provider: "claude")
    workflow = job.latest_workflow
    run = workflow.runs.first

    session = run.create_provider_session!(provider: "claude", session_id: "sticky-session")

    expect(workflow.provider_account).to eq(account)
    expect(run.provider_account).to eq(account)
    expect(session.provider_account).to eq(account)
    expect(account.safe_reference).to include(id: account.public_id)
    expect(account.safe_reference.to_json).not_to include("legacy-token")
  end

  it "keeps legacy-only provider plugins compatible with the migrated default account" do
    legacy_provider = Class.new(AgentProviders::Base) do
      def self.configured_for_user?(user) = user.claude_oauth_token.present?
    end
    user.update!(claude_oauth_token: "legacy-token")

    expect(legacy_provider.configured_for_account?(user.default_provider_account("claude"), user: user)).to be(true)
    expect(legacy_provider.configured_for_account?(create_account(position: 1), user: user)).to be(false)
  end
end
