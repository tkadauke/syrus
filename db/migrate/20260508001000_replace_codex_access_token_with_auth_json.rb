class ReplaceCodexAccessTokenWithAuthJson < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :codex_access_token, :string
    add_column :users, :codex_auth_json, :text
  end
end
