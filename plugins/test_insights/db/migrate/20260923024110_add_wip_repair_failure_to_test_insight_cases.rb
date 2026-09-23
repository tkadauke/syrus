class AddWipRepairFailureToTestInsightCases < ActiveRecord::Migration[8.1]
  # `scored` used to be computed at read time via a correlated EXISTS across
  # test_insight_cases/test_insight_runs/runs/steps (TestCase.wip_repair_failures).
  # MySQL 8's optimizer flattens that EXISTS into a semi-join across all four
  # tables and picks a join order that ignores the test_identity_id index,
  # turning what should be a handful of rows into a multi-billion-row scan
  # (production: avg ~10M rows examined per call, up to 67s). Persisting the
  # classification here lets `scored` become a plain indexed boolean filter;
  # see TestInsights::WipRepairFailureClassifier for how it's kept up to date.
  def up
    unless column_exists?(:test_insight_cases, :wip_repair_failure)
      add_column :test_insight_cases, :wip_repair_failure, :boolean, default: false, null: false
    end

    unless index_exists?(:test_insight_cases, [ :test_identity_id, :wip_repair_failure, :created_at, :id ], name: "idx_test_cases_identity_scored_created_id")
      add_index :test_insight_cases, [ :test_identity_id, :wip_repair_failure, :created_at, :id ], name: "idx_test_cases_identity_scored_created_id"
    end
  end

  def down
    if index_exists?(:test_insight_cases, [ :test_identity_id, :wip_repair_failure, :created_at, :id ], name: "idx_test_cases_identity_scored_created_id")
      remove_index :test_insight_cases, name: "idx_test_cases_identity_scored_created_id"
    end

    if column_exists?(:test_insight_cases, :wip_repair_failure)
      remove_column :test_insight_cases, :wip_repair_failure
    end
  end
end
