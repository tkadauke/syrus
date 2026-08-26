class AddChatMessageActiveTailIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :chat_messages,
              [ :chat_session_id, :deleted_at, :id ],
              name: "idx_chat_messages_active_tail",
              if_not_exists: true
  end
end
