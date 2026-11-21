class AddAllowAsOwnerToConnectedAccountsProviderConfigs < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:connected_accounts_provider_configs, :allow_as_owner)

    add_column :connected_accounts_provider_configs, :allow_as_owner, :boolean, null: false, default: false
  end

  def down
    remove_column :connected_accounts_provider_configs, :allow_as_owner if column_exists?(:connected_accounts_provider_configs, :allow_as_owner)
  end
end
