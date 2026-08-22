class AddSidecarModeToMcpToolUsages < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:mcp_tool_usages, :sidecar_mode)
      add_column :mcp_tool_usages, :sidecar_mode, :string
    end
    unless column_exists?(:mcp_tool_usages, :daemon_worker_id)
      add_column :mcp_tool_usages, :daemon_worker_id, :string
    end

    unless index_exists?(:mcp_tool_usages, [ :surface, :sidecar_mode, :created_at ], name: "idx_mcp_tool_usages_surface_sidecar_mode_window")
      add_index :mcp_tool_usages, [ :surface, :sidecar_mode, :created_at ], name: "idx_mcp_tool_usages_surface_sidecar_mode_window"
    end
  end
end
