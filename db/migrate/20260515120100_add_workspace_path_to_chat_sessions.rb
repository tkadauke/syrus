class AddWorkspacePathToChatSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_sessions, :workspace_path, :string
    add_index :chat_sessions, :workspace_path
  end
end
