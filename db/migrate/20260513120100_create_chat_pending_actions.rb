class AddNoteFieldsToChatPendingActions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_pending_actions, :action, :string unless column_exists?(:chat_pending_actions, :action)
    add_column :chat_pending_actions, :requested_by, :string, null: false, default: "agent" unless column_exists?(:chat_pending_actions, :requested_by)
    add_column :chat_pending_actions, :rejected_at, :datetime unless column_exists?(:chat_pending_actions, :rejected_at)
    add_index :chat_pending_actions, [ :chat_session_id, :state, :created_at ], name: "index_chat_pending_actions_on_session_state" unless index_exists?(:chat_pending_actions, [ :chat_session_id, :state, :created_at ], name: "index_chat_pending_actions_on_session_state")
  end
end
