class AddPinnedToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :pinned, :boolean, default: false, null: false unless column_exists?(:chat_sessions, :pinned)
  end

  def down
    remove_column :chat_sessions, :pinned if column_exists?(:chat_sessions, :pinned)
  end
end
