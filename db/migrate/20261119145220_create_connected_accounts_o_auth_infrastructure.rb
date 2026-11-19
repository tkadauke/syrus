class CreateConnectedAccountsOAuthInfrastructure < ActiveRecord::Migration[8.1]
  def change
    create_table :connected_accounts_provider_configs, if_not_exists: true do |t|
      t.string :provider_key, null: false
      t.string :authorize_url, null: false
      t.string :token_url, null: false
      t.string :revoke_url
      t.string :identity_url, null: false
      t.string :validate_url
      t.string :client_id, null: false
      t.text :client_secret, null: false
      t.json :scope_catalog, null: false
      t.json :api_origins, null: false
      t.timestamps
    end
    add_index :connected_accounts_provider_configs, :provider_key, unique: true, name: "idx_connected_accounts_provider_key", if_not_exists: true

    create_table :connected_accounts_oauth_states, if_not_exists: true do |t|
      t.string :digest, null: false
      t.string :session_digest, null: false
      t.text :code_verifier, null: false
      t.json :requested_scopes, null: false
      t.boolean :read_only, null: false
      t.string :provider, null: false
      t.references :user, null: false, foreign_key: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
    end
    add_index :connected_accounts_oauth_states, :digest, unique: true, name: "idx_connected_accounts_oauth_state_digest", if_not_exists: true
  end
end
