class AddCreatedAtIndexToMcpToolUsages < ActiveRecord::Migration[8.1]
  def change
    unless index_exists?(:mcp_tool_usages, :created_at, name: "index_mcp_tool_usages_on_created_at")
      add_index :mcp_tool_usages, :created_at, name: "index_mcp_tool_usages_on_created_at"
    end
  end
end
