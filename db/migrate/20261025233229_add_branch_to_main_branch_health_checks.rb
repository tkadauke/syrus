class AddBranchToMainBranchHealthChecks < ActiveRecord::Migration[8.1]
  def up
    add_column :main_branch_health_checks, :branch, :string unless column_exists?(:main_branch_health_checks, :branch)

    execute <<~SQL.squish
      UPDATE main_branch_health_checks
      SET branch = (
        SELECT repositories.default_branch
        FROM repositories
        WHERE repositories.id = main_branch_health_checks.repository_id
      )
      WHERE branch IS NULL
    SQL

    change_column_null :main_branch_health_checks, :branch, false
    unless index_exists?(:main_branch_health_checks, [ :repository_id, :branch, :sha ])
      add_index :main_branch_health_checks, [ :repository_id, :branch, :sha ], name: "idx_mbhc_repo_branch_sha"
    end
  end

  def down
    remove_index :main_branch_health_checks, name: "idx_mbhc_repo_branch_sha" if index_exists?(:main_branch_health_checks, name: "idx_mbhc_repo_branch_sha")
    remove_column :main_branch_health_checks, :branch if column_exists?(:main_branch_health_checks, :branch)
  end
end
