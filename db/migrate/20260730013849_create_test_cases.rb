class CreateTestCases < ActiveRecord::Migration[8.1]
  def up
    create_table :test_cases, if_not_exists: true do |t|
      t.bigint :test_run_id, null: false
      t.bigint :repository_id, null: false
      t.string :name, null: false
      t.string :suite_name, null: false
      t.string :file_path
      t.string :status, null: false, limit: 32
      t.integer :duration_ms
      t.text :output
      t.text :failure_message
      t.text :failure_backtrace

      t.timestamps
    end

    add_index :test_cases, :test_run_id unless index_exists?(:test_cases, :test_run_id)
    add_index :test_cases, :repository_id unless index_exists?(:test_cases, :repository_id)
    unless index_exists?(:test_cases, [ :repository_id, :suite_name, :name ], name: "idx_test_cases_repo_suite_name")
      add_index :test_cases, [ :repository_id, :suite_name, :name ], name: "idx_test_cases_repo_suite_name"
    end
    unless index_exists?(:test_cases, [ :test_run_id, :status ], name: "idx_test_cases_run_status")
      add_index :test_cases, [ :test_run_id, :status ], name: "idx_test_cases_run_status"
    end

    add_foreign_key :test_cases, :test_runs unless foreign_key_exists?(:test_cases, :test_runs)
    add_foreign_key :test_cases, :repositories unless foreign_key_exists?(:test_cases, :repositories)
  end

  def down
    drop_table :test_cases, if_exists: true
  end
end
