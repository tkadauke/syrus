class CreateLocalToolCalls < ActiveRecord::Migration[8.1]
  def up
    create_table :local_tool_calls, if_not_exists: true do |t|
      t.references :local_daemon_session, null: false, foreign_key: true
      t.references :chat_session, null: false, foreign_key: true
      t.string :tool_use_id, null: false
      t.string :tool_name, null: false
      # tool_input and result are JSON; MySQL 8 forbids a default value on JSON
      # columns. Add nullable, then make non-null with a backfill if needed later.
      t.json :tool_input
      t.json :result
      t.string :state, null: false
      t.string :error
      t.datetime :dispatched_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :local_tool_calls, :tool_use_id unless index_exists?(:local_tool_calls, :tool_use_id)
    add_index :local_tool_calls, [ :local_daemon_session_id, :state ] unless index_exists?(:local_tool_calls, [ :local_daemon_session_id, :state ])
  end

  def down
    drop_table :local_tool_calls, if_exists: true
  end
end
