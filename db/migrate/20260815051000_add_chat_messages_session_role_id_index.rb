class AddChatMessagesSessionRoleIdIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :chat_messages,
      [ :chat_session_id, :role, :id ],
      name: "idx_chat_messages_session_role_id",
      if_not_exists: true
  end
end
