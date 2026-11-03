class CreateWorkspaceReuseOutcomes < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_reuse_outcomes do |t|
      t.references :repository, null: false, foreign_key: false
      t.references :workflow, null: false, foreign_key: false
      t.references :step, null: false, foreign_key: false
      t.references :run, null: false, foreign_key: false
      t.string :kind, null: false, limit: 32
      t.string :outcome, null: false, limit: 64
      t.string :prepare_fingerprint, limit: 64
      t.string :storage_key
      t.string :backend, null: false, limit: 64
      t.string :materialization_method, limit: 32
      t.text :fallback_reason
      t.integer :grader_count
      t.decimal :duration_seconds, precision: 12, scale: 3
      t.bigint :bytes
      t.datetime :occurred_at, null: false
      t.timestamps

      t.index [ :repository_id, :occurred_at ], name: "idx_workspace_reuse_repo_time"
      t.index [ :prepare_fingerprint, :backend, :occurred_at ], name: "idx_workspace_reuse_fingerprint_backend_time"
      t.index [ :kind, :outcome, :occurred_at ], name: "idx_workspace_reuse_kind_outcome_time"
      t.index [ :occurred_at, :id ], name: "idx_workspace_reuse_retention"
    end
  end
end
