class AddGraderNameToTestInsightCases < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_test_cases_identity_grader_created_id"

  def up
    add_column :test_insight_cases, :grader_name, :string unless column_exists?(:test_insight_cases, :grader_name)
    unless index_exists?(:test_insight_cases, [ :test_identity_id, :grader_name, :created_at, :id ], name: INDEX_NAME)
      add_index :test_insight_cases, [ :test_identity_id, :grader_name, :created_at, :id ], name: INDEX_NAME
    end
  end

  def down
    remove_index :test_insight_cases, name: INDEX_NAME if index_exists?(:test_insight_cases, name: INDEX_NAME)
    remove_column :test_insight_cases, :grader_name if column_exists?(:test_insight_cases, :grader_name)
  end
end
