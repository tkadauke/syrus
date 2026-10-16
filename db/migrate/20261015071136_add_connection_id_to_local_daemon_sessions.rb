class AddConnectionIdToLocalDaemonSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :local_daemon_sessions, :connection_id, :string unless column_exists?(:local_daemon_sessions, :connection_id)
  end
end
