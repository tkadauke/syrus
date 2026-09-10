class CreateTargetHealthRecords < ActiveRecord::Migration[8.1]
  def up
    create_table :target_health_records, if_not_exists: true do |t|
      t.bigint :repository_id, null: false
      t.bigint :workflow_id
      t.bigint :step_id
      t.bigint :run_id
      t.string :target_label, null: false, limit: 255
      t.string :project_id, null: false, limit: 128
      t.string :commit_sha, null: false, limit: 64
      t.string :input_fingerprint, null: false, limit: 64
      t.string :command_fingerprint, null: false, limit: 64
      t.string :environment_fingerprint, null: false, limit: 64
      t.string :status, null: false, limit: 32
      t.datetime :checked_at, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.float :duration_s
      t.integer :exit_code
      t.string :log_path, limit: 1024
      t.bigint :log_bytes
      t.json :artifacts
      t.json :metadata

      t.timestamps
    end

    unless index_exists?(:target_health_records,
                         [ :repository_id, :target_label, :commit_sha ],
                         name: "idx_target_health_records_repo_target_sha")
      add_index :target_health_records,
                [ :repository_id, :target_label, :commit_sha ],
                name: "idx_target_health_records_repo_target_sha"
    end

    unless index_exists?(:target_health_records,
                         [ :repository_id, :target_label, :commit_sha, :input_fingerprint, :command_fingerprint, :environment_fingerprint ],
                         unique: true,
                         name: "idx_target_health_records_identity")
      add_index :target_health_records,
                [ :repository_id, :target_label, :commit_sha, :input_fingerprint, :command_fingerprint, :environment_fingerprint ],
                unique: true,
                name: "idx_target_health_records_identity"
    end

    unless index_exists?(:target_health_records,
                         [ :repository_id, :project_id, :status, :checked_at ],
                         name: "idx_target_health_records_project_status")
      add_index :target_health_records,
                [ :repository_id, :project_id, :status, :checked_at ],
                name: "idx_target_health_records_project_status"
    end

    add_index :target_health_records, :workflow_id unless index_exists?(:target_health_records, :workflow_id)
    add_index :target_health_records, :run_id unless index_exists?(:target_health_records, :run_id)
  end

  def down
    drop_table :target_health_records, if_exists: true
  end
end
