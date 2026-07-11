class CreateLocalDaemonSessions < ActiveRecord::Migration[8.1]
  def up
    create_table :local_daemon_sessions, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true, index: false
      t.references :user, null: false, foreign_key: true
      t.string :repo_slug
      t.string :repo_root
      t.string :branch
      t.string :auth_token, null: false
      t.datetime :connected_at
      t.datetime :disconnected_at
      t.datetime :last_ping_at
      t.timestamps
    end

    unless index_exists?(:local_daemon_sessions, :chat_session_id, unique: true)
      add_index :local_daemon_sessions, :chat_session_id, unique: true
    end
  end

  def down
    drop_table :local_daemon_sessions, if_exists: true
  end
end
