class AddProdHotPathIndexesForActiveRunsAndAgentBackfill < ActiveRecord::Migration[8.1]
  def change
    add_index :runs,
      [ :finished_at, :created_at, :id ],
      name: "idx_runs_active_created",
      if_not_exists: true

    add_index :spawned_processes,
      [ :agent_id, :run_id ],
      name: "idx_spawned_processes_agent_run_backfill",
      if_not_exists: true

    add_index :spawned_processes,
      [ :agent_id, :chat_session_id ],
      name: "idx_spawned_processes_agent_chat_backfill",
      if_not_exists: true
  end
end
