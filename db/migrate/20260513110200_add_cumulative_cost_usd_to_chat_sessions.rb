class AddCumulativeCostUsdToChatSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_sessions,
               :cumulative_cost_usd,
               :decimal,
               precision: 12,
               scale: 6,
               default: 0,
               null: false
  end
end
