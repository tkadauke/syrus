class AddLocalDaemonFieldsToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :local_daemon_state, :string unless column_exists?(:chat_sessions, :local_daemon_state)
    add_column :chat_sessions, :local_daemon_repo, :string unless column_exists?(:chat_sessions, :local_daemon_repo)
    add_column :chat_sessions, :local_daemon_branch, :string unless column_exists?(:chat_sessions, :local_daemon_branch)
  end

  def down
    remove_column :chat_sessions, :local_daemon_branch if column_exists?(:chat_sessions, :local_daemon_branch)
    remove_column :chat_sessions, :local_daemon_repo if column_exists?(:chat_sessions, :local_daemon_repo)
    remove_column :chat_sessions, :local_daemon_state if column_exists?(:chat_sessions, :local_daemon_state)
  end
end
