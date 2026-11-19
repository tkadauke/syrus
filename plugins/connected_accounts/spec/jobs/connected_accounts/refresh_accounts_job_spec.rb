require "rails_helper"

RSpec.describe ConnectedAccounts::RefreshAccountsJob do
  let(:user) { Factories.user }

  before { allow(ConnectedAccounts).to receive(:enabled?).and_return(true) }

  def create_account(label)
    credential = CredentialStore::Credential.create!(name: "oauth-#{label}", credential_type: "connected_accounts.oauth", scope_type: "user",
      scope_id: user.id, created_by: user, owner_user: user,
      payload: { access_token: "access-#{label}", refresh_token: "refresh-#{label}", expires_at: 1.minute.from_now.iso8601 }.to_json,
      safe_metadata: { "refreshable" => true }, target_constraints: { "allowed_url_prefixes" => [ "https://api.example/" ] },
      allowed_tools: [ "connected_accounts.broker" ])
    ConnectedAccounts::Account.create!(provider: "fake", display_label: label, granted_scopes: [ "fake.read" ], status: "connected",
      read_only: true, scope_ceiling: [ "fake.read" ], acting_modes: [ "as_self" ], owner_user: user,
      credential_store_credential: credential)
  end

  it "uses the consumed maintenance queue" do
    expect(described_class.queue_name).to eq("low_priority_maintenance")
  end

  it "fans the recurring batch out into independently retryable account jobs" do
    first = create_account("first@example.com")
    second = create_account("second@example.com")
    allow(ConnectedAccounts::TokenMaintenance).to receive(:call)

    expect { described_class.perform_now }.to have_enqueued_job(described_class).with(first.id)
      .and have_enqueued_job(described_class).with(second.id)
    expect(ConnectedAccounts::TokenMaintenance).not_to have_received(:call)
  end

  it "runs maintenance for one account and lets transient failures use the job retry policy" do
    account = create_account("retry@example.com")
    allow(ConnectedAccounts::TokenMaintenance).to receive(:call).with(account).and_raise(ConnectedAccounts::Provider::TransientError, "try later")

    expect { described_class.perform_now(account.id) }.to have_enqueued_job(described_class).with(account.id)
  end
end
