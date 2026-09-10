class AddMcpToolUsageFilterWindowIndexes < ActiveRecord::Migration[8.0]
  def change
    unless index_exists?(:mcp_tool_usages, [ :normalized_tool_name, :created_at ], name: "idx_mcp_tool_usages_tool_window")
      add_index :mcp_tool_usages,
                [ :normalized_tool_name, :created_at ],
                name: "idx_mcp_tool_usages_tool_window"
    end

    unless index_exists?(:mcp_tool_usages, [ :server_name, :created_at ], name: "idx_mcp_tool_usages_server_window")
      add_index :mcp_tool_usages,
                [ :server_name, :created_at ],
                name: "idx_mcp_tool_usages_server_window"
    end
  end
end
