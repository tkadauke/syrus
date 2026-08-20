class AddLatestLookupIndexToTestCases < ActiveRecord::Migration[8.1]
  def change
    add_index :test_cases,
      [ :test_identity_id, :created_at, :id ],
      name: "idx_test_cases_identity_created_id",
      if_not_exists: true
  end
end
