class CreateTestIdentityRuntimeSummaries < ActiveRecord::Migration[8.1]
  def change
    create_table :test_identity_runtime_summaries do |t|
      t.references :repository, null: false, foreign_key: false
      t.references :test_identity, null: false, foreign_key: false
      t.string :grader_name, limit: 128, null: false
      t.string :window, limit: 32, null: false
      t.integer :sample_count, null: false, default: 0
      t.integer :avg_duration_ms
      t.integer :p50_duration_ms
      t.integer :p95_duration_ms
      t.integer :min_duration_ms
      t.integer :max_duration_ms
      t.datetime :last_observed_at
      t.timestamps

      t.index [ :repository_id, :grader_name, :window, :avg_duration_ms, :test_identity_id ],
        name: "idx_test_runtime_summary_avg"
      t.index [ :repository_id, :grader_name, :window, :p95_duration_ms, :test_identity_id ],
        name: "idx_test_runtime_summary_p95"
      t.index [ :test_identity_id, :grader_name, :window ],
        unique: true,
        name: "idx_test_runtime_summary_identity_grader_window"
    end
  end
end
