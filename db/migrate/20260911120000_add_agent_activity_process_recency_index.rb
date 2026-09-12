class AddAgentActivityProcessRecencyIndex < ActiveRecord::Migration[8.1]
  def change
    columns = [ :kind, :agent_id, :started_at, :id ]
    unless index_exists?(:spawned_processes, columns, name: "idx_spawned_processes_agent_activity_recency")
      add_index :spawned_processes,
                columns,
                name: "idx_spawned_processes_agent_activity_recency"
    end
  end
end
