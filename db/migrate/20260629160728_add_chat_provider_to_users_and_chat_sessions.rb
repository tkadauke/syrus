class AddChatProviderToUsersAndChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :chat_provider, :string unless column_exists?(:users, :chat_provider)
    add_column :chat_sessions, :chat_provider, :string unless column_exists?(:chat_sessions, :chat_provider)
  end

  def down
    remove_column :chat_sessions, :chat_provider if column_exists?(:chat_sessions, :chat_provider)
    remove_column :users, :chat_provider if column_exists?(:users, :chat_provider)
  end
end
