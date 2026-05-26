class RemoveOperatorChatAndTelegram < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE runs
      SET state = 'failed',
          agent_outcome = 'operator_chat_removed',
          finished_at = COALESCE(finished_at, CURRENT_TIMESTAMP)
      WHERE state = 'awaiting_operator'
    SQL

    drop_table :operator_responses, if_exists: true
    drop_table :operator_questions, if_exists: true

    remove_index :runs, name: "index_runs_on_operator_chat_thread_id" if index_exists?(:runs, :operator_chat_thread_id, name: "index_runs_on_operator_chat_thread_id")
    remove_index :runs, name: "index_runs_on_operator_nudge_window" if index_exists?(:runs, [ :state, :nudge_sent, :created_at ], name: "index_runs_on_operator_nudge_window")
    remove_column :runs, :operator_chat_thread_id if column_exists?(:runs, :operator_chat_thread_id)
    remove_column :runs, :operator_chat_response if column_exists?(:runs, :operator_chat_response)
    remove_column :runs, :nudge_sent if column_exists?(:runs, :nudge_sent)

    remove_column :jobs, :operator_chat_disabled if column_exists?(:jobs, :operator_chat_disabled)
    remove_column :repositories, :allow_operator_chat if column_exists?(:repositories, :allow_operator_chat)
    remove_column :users, :telegram_chat_id if column_exists?(:users, :telegram_chat_id)
    remove_column :app_settings, :telegram_bot_token if column_exists?(:app_settings, :telegram_bot_token)
    remove_column :app_settings, :telegram_webhook_secret if column_exists?(:app_settings, :telegram_webhook_secret)
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
