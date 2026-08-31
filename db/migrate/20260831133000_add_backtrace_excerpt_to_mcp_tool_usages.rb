class AddBacktraceExcerptToMcpToolUsages < ActiveRecord::Migration[8.0]
  def change
    add_column :mcp_tool_usages, :backtrace_excerpt, :text unless column_exists?(:mcp_tool_usages, :backtrace_excerpt)
  end
end
