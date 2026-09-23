class CreateMcpStartupPhaseEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_startup_phase_events do |t|
      t.datetime :occurred_at, null: false
      t.string :phase, null: false
      t.string :source, null: false
      t.string :provider
      t.string :server_name
      t.string :tier
      t.references :chat_session, foreign_key: true
      t.references :chat_message, foreign_key: true
      t.references :run, foreign_key: true
      t.string :hostname
      t.integer :pid
      t.string :app_revision
      t.json :metadata, null: false

      t.timestamps
    end

    add_index :mcp_startup_phase_events, :occurred_at
    add_index :mcp_startup_phase_events,
              [ :chat_session_id, :chat_message_id, :occurred_at ],
              name: "idx_mcp_startup_phase_chat_message_occurred"
    add_index :mcp_startup_phase_events, [ :phase, :occurred_at ], name: "idx_mcp_startup_phase_phase_occurred"
    add_index :mcp_startup_phase_events, [ :server_name, :occurred_at ], name: "idx_mcp_startup_phase_server_occurred"
  end
end
