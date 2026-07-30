class CreateJobDeploymentStageStatuses < ActiveRecord::Migration[8.1]
  def change
    create_table :job_deployment_stage_statuses do |t|
      t.references :job, null: false, foreign_key: true, index: true
      t.string :stage_name, null: false
      t.datetime :reached_at, null: false
      t.string :tag_sha
      t.timestamps
    end

    unless index_exists?(:job_deployment_stage_statuses, [ :job_id, :stage_name ])
      add_index :job_deployment_stage_statuses, [ :job_id, :stage_name ], unique: true
    end
  end
end
