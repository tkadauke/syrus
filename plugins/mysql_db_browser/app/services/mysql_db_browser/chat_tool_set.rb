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

    coworker_grant(
      name: "mysql.read",
      label: "Read MySQL connections",
      description: "Browse and query selected agentic-access MySQL connections with enforced read-only access.",
      tools: TOOL_CLASSES,
      default_policy: "confirm",
      max_policy: "auto",
      scope: {
        options: lambda { |user:|
          context = McpToolContext.new(surface: :chat, role: AgentRole::CHAT_PLANNER, user: user)
          AgenticAccess.safe_connection_metadata(context: context).pluck(:id)
        },
        label: ->(id) { MysqlConnection.find_by(id: id)&.label || "MySQL connection #{id}" },
        valid: lambda { |id, user:|
          context = McpToolContext.new(surface: :chat, role: AgentRole::CHAT_PLANNER, user: user)
          AgenticAccess.safe_connection_metadata(context: context).any? { |connection| connection.fetch(:id).to_s == id.to_s }
        }
      }
    )

    def self.available_for?(_chat_session, tier:)
      %i[essential deferred].include?(tier.to_sym) && gated?
    end

    DESCRIPTORS = {
      "mysql_db_browser_list_connections" => "mysql.connection/list@v1",
      "mysql_db_browser_list_databases" => "mysql.database/list@v1",
      "mysql_db_browser_list_tables" => "mysql.table/list@v1",
      "mysql_db_browser_describe_table" => "mysql.schema/read@v1",
      "mysql_db_browser_execute_query" => "mysql.query/execute@v1"
    }.freeze

    def self.tool_definitions(tier: nil, context: nil)
      super.map do |definition|
        definition.merge(capability_descriptor: PermissionProvider.capability_descriptor(DESCRIPTORS.fetch(definition.fetch(:name))))
      end
    end
  end
end
