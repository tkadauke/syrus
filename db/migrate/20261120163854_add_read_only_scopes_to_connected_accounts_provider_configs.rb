class AddReadOnlyScopesToConnectedAccountsProviderConfigs < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:connected_accounts_provider_configs, :read_only_scopes)
      add_column :connected_accounts_provider_configs, :read_only_scopes, :json
    end
    execute "UPDATE connected_accounts_provider_configs SET read_only_scopes = '[]' WHERE read_only_scopes IS NULL"
    change_column_null :connected_accounts_provider_configs, :read_only_scopes, false
  end

  def down
    remove_column :connected_accounts_provider_configs, :read_only_scopes if column_exists?(:connected_accounts_provider_configs, :read_only_scopes)
  end
end
