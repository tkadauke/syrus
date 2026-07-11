class CreateLocalToolCalls < ActiveRecord::Migration[8.1]
  def up
    create_table :local_tool_calls, if_not_exists: true do |t|
      t.references :local_daemon_session, null: false, foreign_key: true
      t.string :tool_name, null: false
      t.json :arguments
      t.json :result
      t.text :error
      t.datetime :dispatched_at
      t.datetime :completed_at
      t.timestamps
    end
  end

  def down
    drop_table :local_tool_calls, if_exists: true
  end
end
