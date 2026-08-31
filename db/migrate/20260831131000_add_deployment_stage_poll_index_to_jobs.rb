class AddDeploymentStagePollIndexToJobs < ActiveRecord::Migration[8.1]
  def change
    add_index :jobs,
              [ :repository_id, :finished_at, :id, :landed_sha ],
              name: "idx_jobs_deployment_stage_poll",
              if_not_exists: true
  end
end
