class RemoveGithubAppWebhookSecretFromAppSettings < ActiveRecord::Migration[8.1]
  def up
    remove_column :app_settings, :github_app_webhook_secret if column_exists?(:app_settings, :github_app_webhook_secret)
  end

  def down
    add_column :app_settings, :github_app_webhook_secret, :text unless column_exists?(:app_settings, :github_app_webhook_secret)
  end
end
