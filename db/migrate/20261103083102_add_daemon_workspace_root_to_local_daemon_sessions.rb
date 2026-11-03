class AddDaemonWorkspaceRootToLocalDaemonSessions < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:local_daemon_sessions, :daemon_workspace_root)

    add_column :local_daemon_sessions, :daemon_workspace_root, :string
  end
end
