class AddRepositoryDetailLookupIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :runs, [ :job_id, :state, :updated_at ],
      name: "idx_runs_job_state_updated_for_repository_detail",
      if_not_exists: true
    add_index :steps, [ :workflow_id, :state, :position, :id ],
      name: "idx_steps_workflow_state_position_for_repository_detail",
      if_not_exists: true
  end
end
