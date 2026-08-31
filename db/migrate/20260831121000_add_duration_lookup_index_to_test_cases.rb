class AddDurationLookupIndexToTestCases < ActiveRecord::Migration[8.1]
  def change
    add_index :test_cases,
      [ :test_identity_id, :duration_ms, :created_at, :id ],
      name: "idx_test_cases_identity_duration_created_id",
      if_not_exists: true
  end
end
