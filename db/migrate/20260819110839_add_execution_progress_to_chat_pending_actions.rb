class AddExecutionProgressToChatPendingActions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_pending_actions, :execution_status, :string unless column_exists?(:chat_pending_actions, :execution_status)
    add_column :chat_pending_actions, :execution_step, :string unless column_exists?(:chat_pending_actions, :execution_step)
    add_column :chat_pending_actions, :execution_error, :text unless column_exists?(:chat_pending_actions, :execution_error)
    add_column :chat_pending_actions, :execution_started_at, :datetime unless column_exists?(:chat_pending_actions, :execution_started_at)
    add_column :chat_pending_actions, :execution_finished_at, :datetime unless column_exists?(:chat_pending_actions, :execution_finished_at)
  end
end
