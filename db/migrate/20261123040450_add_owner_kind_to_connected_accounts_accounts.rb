class AddOwnerKindToConnectedAccountsAccounts < ActiveRecord::Migration[8.1]
  def up
    add_column :connected_accounts_accounts, :owner_kind, :string unless column_exists?(:connected_accounts_accounts, :owner_kind)
    execute "UPDATE connected_accounts_accounts SET owner_kind = 'user' WHERE owner_kind IS NULL"
    change_column_null :connected_accounts_accounts, :owner_kind, false
    change_column_null :connected_accounts_accounts, :owner_user_id, true
    add_index :connected_accounts_accounts, :owner_kind unless index_exists?(:connected_accounts_accounts, :owner_kind)
  end

  def down
    remove_index :connected_accounts_accounts, :owner_kind if index_exists?(:connected_accounts_accounts, :owner_kind)
    remove_column :connected_accounts_accounts, :owner_kind if column_exists?(:connected_accounts_accounts, :owner_kind)
  end
end
