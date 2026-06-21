class AddLastReadAtToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :last_read_at, :datetime unless column_exists?(:chat_sessions, :last_read_at)
  end

  def down
    remove_column :chat_sessions, :last_read_at if column_exists?(:chat_sessions, :last_read_at)
  end
end
