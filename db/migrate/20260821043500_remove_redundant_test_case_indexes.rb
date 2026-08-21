class RemoveRedundantTestCaseIndexes < ActiveRecord::Migration[8.1]
  def change
    remove_index :test_cases, name: "index_test_cases_on_repository_id", if_exists: true
    remove_index :test_cases, name: "index_test_cases_on_test_identity_id", if_exists: true
    remove_index :test_cases, name: "idx_test_cases_identity_created", if_exists: true
    remove_index :test_cases, name: "index_test_cases_on_test_run_id", if_exists: true
  end
end
