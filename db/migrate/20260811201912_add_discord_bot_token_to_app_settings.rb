class AddDiscordBotTokenToAppSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :app_settings, :discord_bot_token, :text unless column_exists?(:app_settings, :discord_bot_token)
  end

  def down
    remove_column :app_settings, :discord_bot_token if column_exists?(:app_settings, :discord_bot_token)
  end
end
