class AddRepositoryDetailSecondaryIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :insight_suggestions, [ :repository_id, :state ],
      name: "idx_insight_suggestions_repo_state",
      if_not_exists: true

    add_index :coverage_snapshots,
      [ :repository_id, :branch, :created_at, :lines_pct, :branches_pct, :functions_pct ],
      name: "idx_coverage_snapshots_repo_branch_trend",
      if_not_exists: true
  end
end
