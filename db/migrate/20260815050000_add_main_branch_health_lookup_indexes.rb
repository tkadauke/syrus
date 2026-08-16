class AddMainBranchHealthLookupIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :main_branch_health_checks,
      [ :repository_id, :sha, :grader_health ],
      name: "idx_mbhc_repo_sha_grader_health",
      if_not_exists: true

    add_index :main_branch_health_checks,
      [ :repository_id, :sha, :ci_health ],
      name: "idx_mbhc_repo_sha_ci_health",
      if_not_exists: true

    add_index :main_branch_health_checks,
      [ :repository_id, :sha, :source, :checked_at ],
      name: "idx_mbhc_repo_sha_source_checked_at",
      if_not_exists: true
  end
end
