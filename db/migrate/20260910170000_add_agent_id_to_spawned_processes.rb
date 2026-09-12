class AddAgentIdToSpawnedProcesses < ActiveRecord::Migration[8.1]
  def up
    add_column :spawned_processes, :agent_id, :bigint unless column_exists?(:spawned_processes, :agent_id)
    add_index :spawned_processes, :agent_id unless index_exists?(:spawned_processes, :agent_id)
  end

  def down
    remove_index :spawned_processes, :agent_id if index_exists?(:spawned_processes, :agent_id)
    remove_column :spawned_processes, :agent_id if column_exists?(:spawned_processes, :agent_id)
  end
end
