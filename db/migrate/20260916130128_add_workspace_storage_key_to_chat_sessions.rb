class AddWorkspaceStorageKeyToChatSessions < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:chat_sessions, :workspace_storage_key)
      add_column :chat_sessions, :workspace_storage_key, :string
    end
  end

  def down
    remove_column :chat_sessions, :workspace_storage_key if column_exists?(:chat_sessions, :workspace_storage_key)
  end
end
