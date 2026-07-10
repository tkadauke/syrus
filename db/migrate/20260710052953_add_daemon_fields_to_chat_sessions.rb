class AddDaemonFieldsToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :daemon_connected, :boolean, default: false, null: false unless column_exists?(:chat_sessions, :daemon_connected)
    add_column :chat_sessions, :daemon_repo, :string unless column_exists?(:chat_sessions, :daemon_repo)
    add_column :chat_sessions, :daemon_branch, :string unless column_exists?(:chat_sessions, :daemon_branch)
  end

  def down
    remove_column :chat_sessions, :daemon_branch if column_exists?(:chat_sessions, :daemon_branch)
    remove_column :chat_sessions, :daemon_repo if column_exists?(:chat_sessions, :daemon_repo)
    remove_column :chat_sessions, :daemon_connected if column_exists?(:chat_sessions, :daemon_connected)
  end
end
