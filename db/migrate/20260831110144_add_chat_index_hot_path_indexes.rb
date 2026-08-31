class AddChatIndexHotPathIndexes < ActiveRecord::Migration[8.1]
  def up
    chat_sessions_index_columns = [ :user_id, :deleted_at, :hidden_at, :system_kind, :pinned, :last_message_at, :created_at, :id ]
    unless index_exists?(:chat_sessions, chat_sessions_index_columns, name: "idx_chat_sessions_active_index_order")
      add_index :chat_sessions,
        chat_sessions_index_columns,
        name: "idx_chat_sessions_active_index_order"
    end

    if table_exists?(:chat_participants)
      unless index_exists?(:chat_participants, [ :user_id, :chat_session_id ], name: "idx_chat_participants_user_session")
        add_index :chat_participants,
          [ :user_id, :chat_session_id ],
          name: "idx_chat_participants_user_session"
      end
    end
  end

  def down
    remove_index :chat_participants, name: "idx_chat_participants_user_session", if_exists: true if table_exists?(:chat_participants)
    remove_index :chat_sessions, name: "idx_chat_sessions_active_index_order", if_exists: true
  end
end
