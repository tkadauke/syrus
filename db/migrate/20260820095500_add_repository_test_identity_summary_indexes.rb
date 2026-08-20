class AddRepositoryTestIdentitySummaryIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :test_identities,
      [ :repository_id, :last_failed_at, :id ],
      name: "idx_test_identities_repo_last_failed",
      if_not_exists: true

    add_index :test_identities,
      [ :repository_id, :last_duration_ms, :last_seen_at, :id ],
      name: "idx_test_identities_repo_last_duration",
      if_not_exists: true

    add_index :test_identities,
      [ :repository_id, :last_passed_at, :id ],
      name: "idx_test_identities_repo_last_passed",
      if_not_exists: true
  end
end
