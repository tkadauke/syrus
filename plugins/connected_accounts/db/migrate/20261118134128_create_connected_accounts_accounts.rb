class CreateConnectedAccountsAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :connected_accounts_accounts, if_not_exists: true do |t|
      t.string :provider, null: false
      t.string :display_label, null: false
      t.json :granted_scopes, null: false
      t.string :status, null: false
      t.boolean :read_only, null: false
      t.json :scope_ceiling
      t.json :acting_modes, null: false
      t.references :owner_user, null: false, foreign_key: false
      t.references :credential_store_credential, null: false, foreign_key: false

      t.timestamps
    end

    unless index_exists?(:connected_accounts_accounts, [ :owner_user_id, :provider ], name: "idx_connected_accounts_owner_provider")
      add_index :connected_accounts_accounts, [ :owner_user_id, :provider ], name: "idx_connected_accounts_owner_provider"
    end
  end
end
