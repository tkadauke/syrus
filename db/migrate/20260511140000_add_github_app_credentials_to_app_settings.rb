class AddGithubAppCredentialsToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :github_app_id, :bigint
    add_column :app_settings, :github_app_slug, :string
    add_column :app_settings, :github_app_private_key_pem, :text
    add_column :app_settings, :github_app_webhook_secret, :text
    add_column :app_settings, :github_app_registered_at, :datetime

    add_index :app_settings, :github_app_id, unique: true
  end
end
