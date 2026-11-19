class CreateProviderAccounts < ActiveRecord::Migration[8.1]
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"

    encrypts :claude_oauth_token
    encrypts :codex_api_key
    encrypts :codex_auth_json
    encrypts :gemini_api_key
    encrypts :muse_api_key
  end

  class MigrationProviderAccount < ActiveRecord::Base
    self.table_name = "provider_accounts"

    encrypts :credential_payload
    serialize :credential_payload, coder: JSON
  end

  def up
    create_table :provider_accounts, if_not_exists: true do |t|
      t.references :user, null: false, foreign_key: false
      t.string :public_id, null: false, limit: 36
      t.string :provider_key, null: false, limit: 64
      t.string :label, limit: 100
      t.string :authentication_kind, null: false, limit: 64
      t.text :credential_payload, null: false
      t.boolean :enabled, null: false, default: true
      t.integer :position, null: false, default: 0
      t.decimal :weight, precision: 8, scale: 3
      t.timestamps
    end

    add_index :provider_accounts, :public_id, unique: true unless index_exists?(:provider_accounts, :public_id)
    add_index :provider_accounts, %i[user_id provider_key position], unique: true,
              name: "idx_provider_accounts_user_provider_position" unless index_exists?(
                :provider_accounts, %i[user_id provider_key position], name: "idx_provider_accounts_user_provider_position"
              )
    add_index :provider_accounts, %i[user_id provider_key enabled position],
              name: "idx_provider_accounts_enabled_order" unless index_exists?(
                :provider_accounts, %i[user_id provider_key enabled position], name: "idx_provider_accounts_enabled_order"
              )
    add_index :provider_accounts, %i[user_id provider_key label], unique: true,
              name: "idx_provider_accounts_user_provider_label" unless index_exists?(
                :provider_accounts, %i[user_id provider_key label], name: "idx_provider_accounts_user_provider_label"
              )

    MigrationUser.find_each do |user|
      backfill_account(user, "claude", "oauth_token", "claude_oauth_token" => user.claude_oauth_token) if user.claude_oauth_token.present?

      codex_credential = user.codex_auth_mode == "chatgpt_login" ? user.codex_auth_json : user.codex_api_key
      if codex_credential.present?
        backfill_account(
          user, "codex", user.codex_auth_mode,
          "codex_auth_mode" => user.codex_auth_mode,
          "codex_api_key" => user.codex_api_key,
          "codex_auth_json" => user.codex_auth_json
        )
      end

      backfill_account(user, "agy", "api_key", "gemini_api_key" => user.gemini_api_key) if user.gemini_api_key.present?
      backfill_account(user, "muse", "api_key", "muse_api_key" => user.muse_api_key) if user.muse_api_key.present?
    end
  end

  def down
    drop_table :provider_accounts, if_exists: true
  end

  private

  def backfill_account(user, provider_key, authentication_kind, payload)
    MigrationProviderAccount.find_or_create_by!(user_id: user.id, provider_key: provider_key, position: 0) do |account|
      account.public_id = SecureRandom.uuid
      account.authentication_kind = authentication_kind
      account.credential_payload = payload.compact
      account.enabled = true
    end
  end
end
