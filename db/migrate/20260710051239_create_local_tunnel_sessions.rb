class CreateLocalTunnelSessions < ActiveRecord::Migration[8.1]
  def up
    create_table :local_tunnel_sessions, if_not_exists: true do |t|
      t.references :user, null: false, foreign_key: true
      t.string :repo_slug
      t.string :branch
      t.string :status, null: false, default: "connected"
      t.integer :chat_session_id
      t.datetime :connected_at
      t.datetime :disconnected_at

      t.timestamps
    end

    add_index :local_tunnel_sessions, [ :user_id, :status ] unless index_exists?(:local_tunnel_sessions, [ :user_id, :status ])
  end

  def down
    drop_table :local_tunnel_sessions, if_exists: true
  end
end
