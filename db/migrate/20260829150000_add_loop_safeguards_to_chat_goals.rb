class AddLoopSafeguardsToChatGoals < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_goals, :consecutive_no_op_iterations, :integer, null: false, default: 0
    add_column :chat_goals, :consecutive_blocked_events, :integer, null: false, default: 0
    add_column :chat_goals, :last_blocked_signature, :string
    add_column :chat_goals, :last_iteration_signature, :string
  end
end
