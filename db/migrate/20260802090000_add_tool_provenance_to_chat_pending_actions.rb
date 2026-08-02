class AddToolProvenanceToChatPendingActions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_pending_actions, :chat_message_id, :bigint unless column_exists?(:chat_pending_actions, :chat_message_id)
    add_column :chat_pending_actions, :tool_use_id, :string unless column_exists?(:chat_pending_actions, :tool_use_id)

    add_index :chat_pending_actions, :chat_message_id unless index_exists?(:chat_pending_actions, :chat_message_id)
    add_index :chat_pending_actions, [ :chat_session_id, :tool_use_id ], name: "index_chat_pending_actions_on_session_and_tool_use_id" unless index_exists?(:chat_pending_actions, [ :chat_session_id, :tool_use_id ], name: "index_chat_pending_actions_on_session_and_tool_use_id")
  end

  def down
    remove_index :chat_pending_actions, name: "index_chat_pending_actions_on_session_and_tool_use_id" if index_exists?(:chat_pending_actions, [ :chat_session_id, :tool_use_id ], name: "index_chat_pending_actions_on_session_and_tool_use_id")
    remove_index :chat_pending_actions, :chat_message_id if index_exists?(:chat_pending_actions, :chat_message_id)
    remove_column :chat_pending_actions, :tool_use_id if column_exists?(:chat_pending_actions, :tool_use_id)
    remove_column :chat_pending_actions, :chat_message_id if column_exists?(:chat_pending_actions, :chat_message_id)
  end
end
