class CreateLocalDaemonSessions < ActiveRecord::Migration[8.1]
  def up
    create_table :local_daemon_sessions, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :auth_token, null: false
      t.string :daemon_repo
      t.string :daemon_branch
      t.datetime :last_heartbeat_at
      t.datetime :disconnected_at

      t.timestamps
    end

    add_index :local_daemon_sessions, :auth_token, unique: true unless index_exists?(:local_daemon_sessions, :auth_token)
  end

  def down
    drop_table :local_daemon_sessions, if_exists: true
  end
end
