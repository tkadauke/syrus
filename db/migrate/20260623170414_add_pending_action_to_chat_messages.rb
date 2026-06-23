class AddPendingActionToChatMessages < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_messages, :pending_action_id, :bigint unless column_exists?(:chat_messages, :pending_action_id)
    add_index :chat_messages, :pending_action_id unless index_exists?(:chat_messages, :pending_action_id)
    add_foreign_key :chat_messages, :chat_pending_actions, column: :pending_action_id unless foreign_key_exists?(:chat_messages, :chat_pending_actions, column: :pending_action_id)
  end

  def down
    remove_foreign_key :chat_messages, column: :pending_action_id if foreign_key_exists?(:chat_messages, :chat_pending_actions, column: :pending_action_id)
    remove_index :chat_messages, :pending_action_id if index_exists?(:chat_messages, :pending_action_id)
    remove_column :chat_messages, :pending_action_id if column_exists?(:chat_messages, :pending_action_id)
  end
end
