class AddLookupIndexesToTestCases < ActiveRecord::Migration[8.1]
  def up
    unless index_exists?(:test_cases, [ :repository_id, :suite_name, :name, :created_at ], name: "idx_test_cases_repo_case_created")
      add_index :test_cases,
        [ :repository_id, :suite_name, :name, :created_at ],
        name: "idx_test_cases_repo_case_created"
    end

    if index_exists?(:test_cases, [ :repository_id, :suite_name, :name ], name: "idx_test_cases_repo_suite_name")
      remove_index :test_cases, name: "idx_test_cases_repo_suite_name"
    end

    unless index_exists?(:test_cases, [ :test_run_id, :status, :suite_name, :name ], name: "idx_test_cases_run_status_case")
      add_index :test_cases,
        [ :test_run_id, :status, :suite_name, :name ],
        name: "idx_test_cases_run_status_case"
    end

    if index_exists?(:test_cases, [ :test_run_id, :status ], name: "idx_test_cases_run_status")
      remove_index :test_cases, name: "idx_test_cases_run_status"
    end
  end

  def down
    unless index_exists?(:test_cases, [ :repository_id, :suite_name, :name ], name: "idx_test_cases_repo_suite_name")
      add_index :test_cases,
        [ :repository_id, :suite_name, :name ],
        name: "idx_test_cases_repo_suite_name"
    end

    if index_exists?(:test_cases, [ :repository_id, :suite_name, :name, :created_at ], name: "idx_test_cases_repo_case_created")
      remove_index :test_cases, name: "idx_test_cases_repo_case_created"
    end

    unless index_exists?(:test_cases, [ :test_run_id, :status ], name: "idx_test_cases_run_status")
      add_index :test_cases,
        [ :test_run_id, :status ],
        name: "idx_test_cases_run_status"
    end

    if index_exists?(:test_cases, [ :test_run_id, :status, :suite_name, :name ], name: "idx_test_cases_run_status_case")
      remove_index :test_cases, name: "idx_test_cases_run_status_case"
    end
  end
end
