class AddCodexAuthModesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :codex_auth_mode, :string, default: "api_key", null: false
    add_column :users, :codex_access_token, :string
  end
end
