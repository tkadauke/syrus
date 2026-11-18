class CreateConnectedAccountsAccounts < ActiveRecord::Migration[8.1]
  def up
    create_table :connected_accounts_accounts, if_not_exists: true do |t|
      t.string :provider_key, null: false
      t.string :display_label, null: false
      t.json :granted_scopes, null: false
      t.string :status, null: false
      t.json :access_ceiling, null: false
      t.json :acting_modes, null: false
      t.references :owner_user, null: false, foreign_key: false
      t.bigint :credential_store_credential_id, null: false
      t.timestamps
    end

    unless index_exists?(:connected_accounts_accounts, :credential_store_credential_id, name: "idx_connected_accounts_credential")
      add_index :connected_accounts_accounts, :credential_store_credential_id,
        unique: true, name: "idx_connected_accounts_credential"
    end
    unless index_exists?(:connected_accounts_accounts, %i[owner_user_id provider_key], name: "idx_connected_accounts_owner_provider")
      add_index :connected_accounts_accounts, %i[owner_user_id provider_key],
        name: "idx_connected_accounts_owner_provider"
    end
    add_index :connected_accounts_accounts, :status unless index_exists?(:connected_accounts_accounts, :status)
  end

  def down
    drop_table :connected_accounts_accounts, if_exists: true
  end
end
