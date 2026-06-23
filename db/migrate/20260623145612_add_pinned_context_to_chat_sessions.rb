class AddPinnedContextToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :pinned_context, :text unless column_exists?(:chat_sessions, :pinned_context)
  end

  def down
    remove_column :chat_sessions, :pinned_context if column_exists?(:chat_sessions, :pinned_context)
  end
end
