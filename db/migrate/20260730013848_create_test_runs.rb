class CreateTestRuns < ActiveRecord::Migration[8.1]
  def up
    create_table :test_runs, if_not_exists: true do |t|
      t.bigint :run_id, null: false
      t.bigint :repository_id, null: false
      t.string :grader_name, null: false, limit: 128
      t.integer :total_count, null: false, default: 0
      t.integer :passed_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.integer :error_count, null: false, default: 0
      t.integer :duration_ms

      t.timestamps
    end

    add_index :test_runs, :run_id unless index_exists?(:test_runs, :run_id)
    add_index :test_runs, :repository_id unless index_exists?(:test_runs, :repository_id)
    unless index_exists?(:test_runs, [ :run_id, :grader_name ], name: "idx_test_runs_run_grader_unique")
      add_index :test_runs, [ :run_id, :grader_name ], unique: true, name: "idx_test_runs_run_grader_unique"
    end

    add_foreign_key :test_runs, :runs unless foreign_key_exists?(:test_runs, :runs)
    add_foreign_key :test_runs, :repositories unless foreign_key_exists?(:test_runs, :repositories)
  end

  def down
    drop_table :test_runs, if_exists: true
  end
end
