class AddAgentActivityProcessRecencyIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :spawned_processes,
              [ :kind, :agent_id, :started_at, :id ],
              name: "idx_spawned_processes_agent_activity_recency"
  end
end
