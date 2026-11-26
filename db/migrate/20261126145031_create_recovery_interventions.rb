class CreateRecoveryInterventions < ActiveRecord::Migration[8.1]
  def up
    create_table :recovery_interventions, if_not_exists: true do |t|
      t.integer :job_id, null: false
      t.integer :source_workflow_id
      t.integer :source_step_id
      t.integer :source_run_id
      t.integer :resulting_workflow_id
      t.integer :resulting_step_id
      t.integer :resulting_run_id
      t.string :source_loop_id
      t.string :actor_type, null: false
      t.integer :actor_id
      t.string :actor_display
      t.string :origin, null: false
      t.string :action, null: false
      t.string :recovery_kind, null: false
      t.string :recovery_mode, null: false
      t.text :reason
      t.text :guidance
      t.string :source_revision
      t.string :resulting_revision
      t.string :failure_classification
      t.json :failure_evidence
      t.datetime :performed_at, null: false
      t.timestamps
    end

    add_index :recovery_interventions, [ :job_id, :performed_at ], name: "idx_recovery_interventions_job_time" unless index_exists?(:recovery_interventions, [ :job_id, :performed_at ], name: "idx_recovery_interventions_job_time")
    add_index :recovery_interventions, :source_workflow_id unless index_exists?(:recovery_interventions, :source_workflow_id)
    add_index :recovery_interventions, :resulting_workflow_id unless index_exists?(:recovery_interventions, :resulting_workflow_id)
  end

  def down
    drop_table :recovery_interventions, if_exists: true
  end
end
