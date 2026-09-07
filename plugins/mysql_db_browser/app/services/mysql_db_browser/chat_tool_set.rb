require "mcp"

module MysqlDbBrowser
  # Schema-browse and query-execution tools for workflow/chat agents,
  # gated per-connection rather than globally: availability only requires
  # the plugin to be enabled and at least one MysqlConnection to have opted
  # into agentic access, since the real authorization check (which specific
  # connection, per AgenticAccess) happens inside each tool's #call once the
  # agent names a mysql_connection_id.
  class ChatToolSet
    include Syrus::Plugin::GatedToolSet

    gated_by plugin: MysqlDbBrowser, model: MysqlConnection, label: "MySQL DB Browser"

    TOOL_CLASSES = [
      ListConnectionsTool,
      ListDatabasesTool,
      ListTablesTool,
      DescribeTableTool,
      ExecuteQueryTool
    ].freeze

    def self.available_for?(_chat_session, tier:)
      %i[essential deferred].include?(tier.to_sym) && gated?
    end
  end
end
