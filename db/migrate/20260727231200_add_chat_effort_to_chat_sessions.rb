class AddChatEffortToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :chat_effort, :string unless column_exists?(:chat_sessions, :chat_effort)
  end

  def down
    remove_column :chat_sessions, :chat_effort if column_exists?(:chat_sessions, :chat_effort)
  end
end
