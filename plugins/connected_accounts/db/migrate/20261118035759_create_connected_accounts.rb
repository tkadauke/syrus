class CreateConnectedAccounts < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:connected_accounts)

    create_table :connected_accounts do |t|
      t.string :provider_key, null: false
      t.string :display_label, null: false
      t.json :granted_scopes, null: false
      t.string :status, null: false
      t.json :scope_ceiling, null: false
      t.json :acting_modes, null: false
      t.bigint :owner_user_id, null: false
      t.bigint :credential_store_credential_id, null: false
      t.timestamps
    end
    add_index :connected_accounts, :owner_user_id unless index_exists?(:connected_accounts, :owner_user_id)
    add_index :connected_accounts, :credential_store_credential_id,
      unique: true, name: "idx_connected_accounts_credential" unless index_exists?(:connected_accounts, :credential_store_credential_id, name: "idx_connected_accounts_credential")
    add_index :connected_accounts, [ :owner_user_id, :provider_key ],
      name: "idx_connected_accounts_owner_provider" unless index_exists?(:connected_accounts, [ :owner_user_id, :provider_key ], name: "idx_connected_accounts_owner_provider")
  end

  def down
    drop_table :connected_accounts, if_exists: true
  end
end
