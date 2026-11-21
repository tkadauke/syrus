require "rails_helper"
require Rails.root.join("db/migrate/20261120163854_add_read_only_scopes_to_connected_accounts_provider_configs")

RSpec.describe AddReadOnlyScopesToConnectedAccountsProviderConfigs, :ci_only do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  around do |example|
    connection.remove_column(:connected_accounts_provider_configs, :read_only_scopes)
    ConnectedAccounts::ProviderConfig.reset_column_information
    example.run
  ensure
    migration.up
    connection.schema_cache.clear!
    ConnectedAccounts::ProviderConfig.reset_column_information
  end

  it "adds and backfills the column for databases that ran the original migration" do
    connection.execute(<<~SQL)
      INSERT INTO connected_accounts_provider_configs
        (provider_key, authorize_url, token_url, identity_url, client_id, client_secret, scope_catalog, api_origins, created_at, updated_at)
      VALUES
        ('legacy', 'https://oauth.example/authorize', 'https://oauth.example/token', 'https://api.example/me',
         'client', 'secret', '[]', '[]', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL

    migration.up
    connection.schema_cache.clear!
    ConnectedAccounts::ProviderConfig.reset_column_information

    config = ConnectedAccounts::ProviderConfig.find_by!(provider_key: "legacy")
    expect(config.read_only_scopes).to eq([])
    expect(connection.columns(:connected_accounts_provider_configs).find { |column| column.name == "read_only_scopes" }.null).to be(false)
  end

  it "is idempotent" do
    expect { migration.up; migration.up }.not_to raise_error
  end
end
