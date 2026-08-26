class AddErrorStartedAtIndexToMcpToolUsages < ActiveRecord::Migration[8.1]
  def change
    unless index_exists?(:mcp_tool_usages, [ :error, :started_at ], name: "idx_mcp_tool_usages_error_started_at")
      add_index :mcp_tool_usages, [ :error, :started_at ], name: "idx_mcp_tool_usages_error_started_at"
    end
  end
end
