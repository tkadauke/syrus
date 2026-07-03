class DropTelegramColumnsFromUsersAndAppSettings < ActiveRecord::Migration[8.1]
  def up
    remove_column :users, :telegram_chat_id if column_exists?(:users, :telegram_chat_id)
    remove_column :app_settings, :telegram_bot_token if column_exists?(:app_settings, :telegram_bot_token)
    remove_column :app_settings, :telegram_webhook_secret if column_exists?(:app_settings, :telegram_webhook_secret)
  end

  def down
    add_column :users, :telegram_chat_id, :text unless column_exists?(:users, :telegram_chat_id)
    add_column :app_settings, :telegram_bot_token, :text unless column_exists?(:app_settings, :telegram_bot_token)
    add_column :app_settings, :telegram_webhook_secret, :text unless column_exists?(:app_settings, :telegram_webhook_secret)
  end
end
