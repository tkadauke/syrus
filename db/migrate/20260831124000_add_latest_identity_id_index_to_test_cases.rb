class AddLatestIdentityIdIndexToTestCases < ActiveRecord::Migration[8.1]
  def change
    add_index :test_cases,
      [ :test_identity_id, :id ],
      name: "idx_test_cases_identity_id_latest",
      if_not_exists: true
  end
end
