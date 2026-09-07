require "mcp"

module MysqlDbBrowser
  # Schema-browse and query-execution tools for workflow/chat agents,
  # gated per-connection rather than globally: availability only requires
  # the plugin to be enabled and at least one MysqlConnection to have opted
  # into agentic access, since the real authorization check (which specific
  # connection, per AgenticAccess) happens inside each tool's #call once the
  # agent names a mysql_connection_id. See Syrus::Plugin::GatedToolSet for
  # the shared skeleton this and K8sCluster::ChatToolSet both include.
  class ChatToolSet
    include Syrus::Plugin::GatedToolSet

    TOOL_CLASSES = [
      ListConnectionsTool,
      ListDatabasesTool,
      ListTablesTool,
      DescribeTableTool,
      ExecuteQueryTool
    ].freeze

    gated_by MysqlDbBrowser, model: MysqlConnection, tool_set_label: "MySQL DB Browser"
  end
end
