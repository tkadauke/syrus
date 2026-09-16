class AddMuseApiKeyToUsers < ActiveRecord::Migration[8.1]
  # Encrypted at the model layer (User `encrypts :muse_api_key`), same as
  # codex_api_key -- a plain text column here.
  def up
    add_column :users, :muse_api_key, :text unless column_exists?(:users, :muse_api_key)
  end

  def down
    remove_column :users, :muse_api_key if column_exists?(:users, :muse_api_key)
  end
end
