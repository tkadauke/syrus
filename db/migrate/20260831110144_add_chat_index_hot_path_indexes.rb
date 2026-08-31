class AddChatIndexHotPathIndexes < ActiveRecord::Migration[8.1]
  def up
    add_index :chat_sessions,
      [ :user_id, :deleted_at, :hidden_at, :system_kind, :pinned, :last_message_at, :created_at, :id ],
      name: "idx_chat_sessions_active_index_order",
      if_not_exists: true

    add_index :chat_participants,
      [ :user_id, :chat_session_id ],
      name: "idx_chat_participants_user_session",
      if_not_exists: true
  end

  def down
    remove_index :chat_participants, name: "idx_chat_participants_user_session", if_exists: true
    remove_index :chat_sessions, name: "idx_chat_sessions_active_index_order", if_exists: true
  end
end
