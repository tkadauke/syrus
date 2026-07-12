class CreateMainBranchHealthChecks < ActiveRecord::Migration[8.1]
  def change
    create_table :main_branch_health_checks, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: true
      t.string :sha, null: false
      t.datetime :checked_at, null: false
      t.string :ci_health, null: false, default: "unknown"
      t.string :grader_health, null: false, default: "unknown"
      t.json :ci_failed_checks
      t.json :grader_failed_names
      t.string :source, null: false
      t.timestamps
    end

    add_index :main_branch_health_checks, [ :repository_id, :checked_at ], name: "idx_mbhc_repo_checked_at" unless index_exists?(:main_branch_health_checks, [ :repository_id, :checked_at ], name: "idx_mbhc_repo_checked_at")
  end
end
