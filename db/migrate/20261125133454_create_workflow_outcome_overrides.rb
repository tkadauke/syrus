class CreateWorkflowOutcomeOverrides < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:workflow_outcome_overrides)

    create_table :workflow_outcome_overrides do |t|
      t.references :job, null: false, foreign_key: false
      t.references :workflow, null: true, foreign_key: false
      t.references :step, null: true, foreign_key: false
      t.references :actor, polymorphic: true, null: false, foreign_key: false
      t.string :gate_kind, null: false
      t.string :gate_identity, null: false
      t.string :original_outcome, null: false
      t.string :candidate_head_sha, null: false
      t.string :candidate_tree_sha
      t.string :candidate_base_sha
      t.string :plan_version
      t.string :prompt_version
      t.string :evidence_digest, null: false
      t.string :fingerprint_digest, null: false
      t.string :channel, null: false
      t.text :reason, null: false
      t.json :permission_decision, null: false
      t.datetime :consumed_at
      t.string :invalidation_cause
      t.timestamps
    end

    add_index :workflow_outcome_overrides, [ :gate_kind, :gate_identity, :fingerprint_digest ],
      name: "idx_workflow_outcome_overrides_fingerprint"
    add_index :workflow_outcome_overrides, [ :job_id, :created_at ],
      name: "idx_workflow_outcome_overrides_job_created"
  end

  def down
    drop_table :workflow_outcome_overrides if table_exists?(:workflow_outcome_overrides)
  end
end
