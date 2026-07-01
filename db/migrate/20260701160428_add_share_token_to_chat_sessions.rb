class AddShareTokenToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :share_token, :string unless column_exists?(:chat_sessions, :share_token)
    add_index :chat_sessions, :share_token, unique: true unless index_exists?(:chat_sessions, :share_token)
  end

  def down
    remove_index :chat_sessions, :share_token if index_exists?(:chat_sessions, :share_token)
    remove_column :chat_sessions, :share_token if column_exists?(:chat_sessions, :share_token)
  end
end
