class AddLoopSafeguardsToChatGoals < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:chat_goals, :consecutive_no_op_iterations)
      add_column :chat_goals, :consecutive_no_op_iterations, :integer, null: false, default: 0
    end

    unless column_exists?(:chat_goals, :consecutive_blocked_events)
      add_column :chat_goals, :consecutive_blocked_events, :integer, null: false, default: 0
    end

    add_column :chat_goals, :last_blocked_signature, :string unless column_exists?(:chat_goals, :last_blocked_signature)
    add_column :chat_goals, :last_iteration_signature, :string unless column_exists?(:chat_goals, :last_iteration_signature)
  end
end
