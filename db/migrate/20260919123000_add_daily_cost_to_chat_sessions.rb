class AddDailyCostToChatSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_sessions,
               :daily_cost_usd,
               :decimal,
               precision: 12,
               scale: 6,
               default: 0,
               null: false
    add_column :chat_sessions, :daily_cost_date, :date
    add_index :chat_sessions,
              [ :user_id, :daily_cost_date, :daily_cost_usd ],
              name: "idx_chat_sessions_daily_spend"
  end
end
