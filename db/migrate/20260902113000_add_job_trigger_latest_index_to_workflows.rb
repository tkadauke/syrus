class AddJobTriggerLatestIndexToWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_index :workflows, [ :job_id, :trigger_kind, :created_at, :id ],
      name: "idx_workflows_job_trigger_created_id",
      if_not_exists: true
  end
end
