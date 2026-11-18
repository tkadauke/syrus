class AddOAuthLifecycleToConnectedAccounts < ActiveRecord::Migration[8.1]
  def up
    create_table :connected_accounts_provider_configs, if_not_exists: true do |t|
      t.string :key, null: false
      t.string :display_name, null: false
      t.string :authorize_url, null: false
      t.string :token_url, null: false
      t.string :revoke_url
      t.string :identity_url
      t.json :scopes, null: false
      t.json :api_origins, null: false
      t.references :credential_store_credential, null: false, foreign_key: false
      t.references :created_by, null: false, foreign_key: false
      t.timestamps
    end
    add_index :connected_accounts_provider_configs, :key, unique: true unless index_exists?(:connected_accounts_provider_configs, :key)

    create_table :connected_accounts_pending_flows, if_not_exists: true do |t|
      t.string :state_digest, null: false
      t.string :provider, null: false
      t.json :requested_scopes, null: false
      t.boolean :read_only, null: false
      t.string :redirect_uri, null: false
      t.text :code_verifier
      t.references :owner_user, null: false, foreign_key: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :connected_accounts_pending_flows, :state_digest, unique: true unless index_exists?(:connected_accounts_pending_flows, :state_digest)
    add_index :connected_accounts_pending_flows, :expires_at unless index_exists?(:connected_accounts_pending_flows, :expires_at)

    add_column :connected_accounts_accounts, :token_expires_at, :datetime unless column_exists?(:connected_accounts_accounts, :token_expires_at)
    add_column :connected_accounts_accounts, :last_health_checked_at, :datetime unless column_exists?(:connected_accounts_accounts, :last_health_checked_at)
    add_column :connected_accounts_accounts, :health_message, :string unless column_exists?(:connected_accounts_accounts, :health_message)
    add_index :connected_accounts_accounts, :token_expires_at unless index_exists?(:connected_accounts_accounts, :token_expires_at)
  end

  def down
    remove_index :connected_accounts_accounts, :token_expires_at if index_exists?(:connected_accounts_accounts, :token_expires_at)
    remove_column :connected_accounts_accounts, :health_message if column_exists?(:connected_accounts_accounts, :health_message)
    remove_column :connected_accounts_accounts, :last_health_checked_at if column_exists?(:connected_accounts_accounts, :last_health_checked_at)
    remove_column :connected_accounts_accounts, :token_expires_at if column_exists?(:connected_accounts_accounts, :token_expires_at)
    drop_table :connected_accounts_pending_flows, if_exists: true
    drop_table :connected_accounts_provider_configs, if_exists: true
  end
end
