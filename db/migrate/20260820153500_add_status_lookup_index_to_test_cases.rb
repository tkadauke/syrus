class AddStatusLookupIndexToTestCases < ActiveRecord::Migration[8.1]
  def change
    add_index :test_cases,
      [ :test_identity_id, :status, :created_at ],
      name: "idx_test_cases_identity_status_created",
      if_not_exists: true
  end
end
