class AddDaemonWorkerIdIndexToMcpToolUsages < ActiveRecord::Migration[8.1]
  def change
    unless index_exists?(:mcp_tool_usages, [ :daemon_worker_id, :created_at ], name: "idx_mcp_tool_usages_daemon_worker_window")
      add_index :mcp_tool_usages,
                [ :daemon_worker_id, :created_at ],
                name: "idx_mcp_tool_usages_daemon_worker_window"
    end
  end
end
