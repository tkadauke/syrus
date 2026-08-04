class CreateWorkflowStepResourceProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :workflow_step_resource_profiles, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: true
      t.string :agent_provider, limit: 64, null: false
      t.string :trigger_kind, limit: 64, null: false
      t.string :step_kind, limit: 64, null: false
      t.string :grader_name, limit: 128, null: false, default: ""
      t.string :job_kind, limit: 64, null: false, default: ""
      t.integer :sample_count, null: false, default: 0
      t.float :p50_duration_seconds
      t.float :p90_duration_seconds
      t.float :p99_duration_seconds
      t.float :p50_cpu_pressure
      t.float :p90_cpu_pressure
      t.float :p99_cpu_pressure
      t.float :p50_io_pressure
      t.float :p90_io_pressure
      t.float :p99_io_pressure
      t.float :p50_memory_used_percent
      t.float :p90_memory_used_percent
      t.float :p99_memory_used_percent
      t.float :timeout_rate, null: false, default: 0.0
      t.float :failure_rate, null: false, default: 0.0
      t.datetime :last_observed_at
      t.integer :profile_version, null: false
      t.timestamps

      t.index [
        :repository_id,
        :agent_provider,
        :trigger_kind,
        :step_kind,
        :grader_name,
        :job_kind
      ], unique: true, name: "idx_workflow_step_resource_profiles_key"
      t.index :last_observed_at, name: "idx_workflow_step_resource_profiles_observed"
    end
  end
end
