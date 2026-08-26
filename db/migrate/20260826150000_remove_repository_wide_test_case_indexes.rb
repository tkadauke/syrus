class RemoveRepositoryWideTestCaseIndexes < ActiveRecord::Migration[8.1]
  def up
    remove_index :test_cases, name: "idx_test_cases_repo_status_created", if_exists: true
    remove_index :test_cases, name: "idx_test_cases_repo_case_created", if_exists: true
  end

  def down
    add_index :test_cases,
      [ :repository_id, :status, :created_at ],
      name: "idx_test_cases_repo_status_created",
      if_not_exists: true

    add_index :test_cases,
      [ :repository_id, :suite_name, :name, :created_at ],
      name: "idx_test_cases_repo_case_created",
      if_not_exists: true
  end
end
