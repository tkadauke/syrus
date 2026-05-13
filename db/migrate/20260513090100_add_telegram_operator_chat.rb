class AddTelegramOperatorChat < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :telegram_chat_id, :text unless column_exists?(:users, :telegram_chat_id)

    add_column :app_settings, :telegram_bot_token, :text unless column_exists?(:app_settings, :telegram_bot_token)
    add_column :app_settings, :telegram_webhook_secret, :text unless column_exists?(:app_settings, :telegram_webhook_secret)

    add_column :runs, :operator_chat_thread_id, :string unless column_exists?(:runs, :operator_chat_thread_id)
    add_column :runs, :operator_chat_response, :text unless column_exists?(:runs, :operator_chat_response)

    add_index :runs, :operator_chat_thread_id unless index_exists?(:runs, :operator_chat_thread_id)
  end
end
