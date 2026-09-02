class AddRepositoryIdentityLookupIndexToTestCases < ActiveRecord::Migration[8.1]
  def change
    add_index :test_cases,
      [ :repository_id, :test_identity_id, :id ],
      name: "idx_test_cases_repo_identity_id",
      if_not_exists: true
  end
end
