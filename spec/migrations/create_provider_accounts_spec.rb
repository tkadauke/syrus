require "rails_helper"
require Rails.root.join("db/migrate/20261119185410_create_provider_accounts")

RSpec.describe CreateProviderAccounts, :ci_only do
  let(:migration) { described_class.new }

  after do
    migration.up unless ActiveRecord::Base.connection.table_exists?(:provider_accounts)
  end

  it "backfills one encrypted default account for each configured provider without clearing legacy credentials" do
    user = Factories.user
    migration.down
    user.update_columns(
      claude_oauth_token: "oat-legacy",
      codex_auth_mode: "api_key",
      codex_api_key: "sk-legacy"
    )

    migration.up

    accounts = ProviderAccount.where(user_id: user.id).order(:provider_key)
    expect(accounts.map { |account| [ account.provider_key, account.position ] }).to eq(
      [[ "claude", 0 ], [ "codex", 0 ]]
    )
    expect(accounts.first.credential_payload).to eq("claude_oauth_token" => "oat-legacy")
    expect(user.reload).to have_attributes(claude_oauth_token: "oat-legacy", codex_api_key: "sk-legacy")

    stored = ActiveRecord::Base.connection.select_values("SELECT credential_payload FROM provider_accounts")
    expect(stored.join).not_to include("oat-legacy", "sk-legacy")
  end
end
