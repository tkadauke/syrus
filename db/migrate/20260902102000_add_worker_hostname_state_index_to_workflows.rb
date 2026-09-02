class AddWorkerHostnameStateIndexToWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_index :workflows,
              [ :worker_hostname, :state, :id ],
              name: "idx_workflows_worker_hostname_state_id",
              if_not_exists: true
  end
end
