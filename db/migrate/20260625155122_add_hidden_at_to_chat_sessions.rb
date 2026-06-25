class AddHiddenAtToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :hidden_at, :datetime unless column_exists?(:chat_sessions, :hidden_at)
    add_index :chat_sessions, [ :user_id, :hidden_at ], name: "index_chat_sessions_on_user_id_and_hidden_at" unless index_exists?(:chat_sessions, [ :user_id, :hidden_at ], name: "index_chat_sessions_on_user_id_and_hidden_at")
  end

  def down
    remove_index :chat_sessions, name: "index_chat_sessions_on_user_id_and_hidden_at" if index_exists?(:chat_sessions, name: "index_chat_sessions_on_user_id_and_hidden_at")
    remove_column :chat_sessions, :hidden_at if column_exists?(:chat_sessions, :hidden_at)
  end
end
