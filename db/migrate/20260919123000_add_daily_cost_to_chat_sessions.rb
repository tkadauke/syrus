class AddDailyCostToChatSessions < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:chat_sessions, :daily_cost_usd)
      add_column :chat_sessions,
                 :daily_cost_usd,
                 :decimal,
                 precision: 12,
                 scale: 6,
                 default: 0,
                 null: false
    end
    add_column :chat_sessions, :daily_cost_date, :date unless column_exists?(:chat_sessions, :daily_cost_date)

    daily_cost_index_columns = [ :user_id, :daily_cost_date, :daily_cost_usd ]
    daily_cost_index_name = "idx_chat_sessions_daily_spend"
    unless index_exists?(:chat_sessions, daily_cost_index_columns, name: daily_cost_index_name)
      add_index :chat_sessions, daily_cost_index_columns, name: daily_cost_index_name
    end
  end
end
