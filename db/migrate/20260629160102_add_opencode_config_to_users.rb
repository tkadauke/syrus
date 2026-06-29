class AddOpencodeConfigToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :opencode_backend, :string unless column_exists?(:users, :opencode_backend)
    add_column :users, :opencode_model, :string unless column_exists?(:users, :opencode_model)
    add_column :users, :opencode_api_key, :text unless column_exists?(:users, :opencode_api_key)
    add_column :users, :opencode_endpoint_url, :string unless column_exists?(:users, :opencode_endpoint_url)
  end

  def down
    remove_column :users, :opencode_endpoint_url if column_exists?(:users, :opencode_endpoint_url)
    remove_column :users, :opencode_api_key if column_exists?(:users, :opencode_api_key)
    remove_column :users, :opencode_model if column_exists?(:users, :opencode_model)
    remove_column :users, :opencode_backend if column_exists?(:users, :opencode_backend)
  end
end
