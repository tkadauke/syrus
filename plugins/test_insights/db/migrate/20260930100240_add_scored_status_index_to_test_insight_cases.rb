class AddScoredStatusIndexToTestInsightCases < ActiveRecord::Migration[8.1]
  def change
    unless index_exists?(:test_insight_cases, [ :test_identity_id, :wip_repair_failure, :status, :created_at ], name: "idx_test_cases_identity_scored_status_created")
      add_index :test_insight_cases,
        [ :test_identity_id, :wip_repair_failure, :status, :created_at ],
        name: "idx_test_cases_identity_scored_status_created"
    end
  end
end
