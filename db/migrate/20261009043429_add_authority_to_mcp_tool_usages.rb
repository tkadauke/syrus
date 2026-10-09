class AddAuthorityToMcpToolUsages < ActiveRecord::Migration[8.1]
  def change
    add_column :mcp_tool_usages, :authority, :string unless column_exists?(:mcp_tool_usages, :authority)

    unless index_exists?(:mcp_tool_usages, [ :authority, :created_at ], name: "idx_mcp_tool_usages_authority_window")
      add_index :mcp_tool_usages, [ :authority, :created_at ], name: "idx_mcp_tool_usages_authority_window"
    end
  end
end
