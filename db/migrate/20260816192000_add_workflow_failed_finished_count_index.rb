class AddWorkflowFailedFinishedCountIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :workflows,
      [ :state, :finished_at, :job_id ],
      name: "idx_workflows_state_finished_job",
      if_not_exists: true
  end
end
