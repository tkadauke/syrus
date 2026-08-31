class AddRunIdentityLookupIndexToTestCases < ActiveRecord::Migration[8.1]
  def change
    add_index :test_cases,
      [ :test_run_id, :test_identity_id ],
      name: "idx_test_cases_run_identity",
      if_not_exists: true
  end
end
