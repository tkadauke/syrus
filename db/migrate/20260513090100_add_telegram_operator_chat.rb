class AddTelegramOperatorChat < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :telegram_chat_id, :text

    add_column :app_settings, :telegram_bot_token, :text
    add_column :app_settings, :telegram_webhook_secret, :text

    add_column :repositories, :allow_operator_chat, :string, default: "in_syrus", null: false

    add_column :runs, :operator_chat_thread_id, :string
    add_column :runs, :operator_chat_response, :text

    add_index :runs, :operator_chat_thread_id
  end
end
