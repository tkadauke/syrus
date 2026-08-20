class CreateRunCheckpoints < ActiveRecord::Migration[8.1]
  def change
    create_table :run_checkpoints, if_not_exists: true do |t|
      t.integer :run_id, null: false
      t.integer :workflow_id, null: false
      t.integer :step_id, null: false
      t.integer :job_id, null: false
      t.integer :repository_id, null: false
      t.integer :user_id, null: false
      t.string :step_kind, null: false
      t.string :commit_sha, null: false
      t.string :base_sha
      t.string :remote_ref, null: false
      t.string :status, null: false, default: "pending"
      t.text :error_message
      t.datetime :published_at
      t.timestamps

      t.index :run_id, unique: true, name: "idx_run_checkpoints_run_unique"
      t.index :remote_ref, unique: true, name: "idx_run_checkpoints_remote_ref_unique"
      t.index [ :job_id, :created_at ], name: "idx_run_checkpoints_job_created"
      t.index [ :workflow_id, :step_id ], name: "idx_run_checkpoints_workflow_step"
      t.index [ :repository_id, :created_at ], name: "idx_run_checkpoints_repository_created"
    end
  end
end
