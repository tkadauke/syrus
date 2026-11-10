class CreateRunDiffs < ActiveRecord::Migration[8.1]
  def up
    create_table :run_diffs, if_not_exists: true do |t|
      t.bigint :run_id, null: false
      t.text :agent_diff, limit: 16_777_215
      t.text :step_agent_diff, limit: 16_777_215
      t.timestamps
    end
    add_index :run_diffs, :run_id, unique: true unless index_exists?(:run_diffs, :run_id)
  end

  def down
    drop_table :run_diffs if table_exists?(:run_diffs)
  end
end
