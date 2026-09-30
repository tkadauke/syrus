class AddScoredStatusIndexToTestInsightCases < ActiveRecord::Migration[8.1]
  def change
    add_index :test_insight_cases,
      [ :test_identity_id, :wip_repair_failure, :status, :created_at ],
      name: "idx_test_cases_identity_scored_status_created",
      if_not_exists: true
  end
end
