require "mysql_db_browser/version"
require "mysql_db_browser/engine"

module MysqlDbBrowser
  def self.register!
    MysqlDbBrowser::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet) unless MysqlDbBrowser::ChatToolSet < Syrus::Plugin::ChatMcpToolSet

    Syrus::PluginRegistry.register(
      name:            "mysql_db_browser",
      display_name:    "MySQL DB Browser",
      version:         MysqlDbBrowser::VERSION,
      default_enabled: false,
      disableable:     true,
      category:        "observability",
      description:     "Register and manage connections to external MySQL databases with encrypted credential storage.",
      homepage:        "https://github.com/tkadauke/syrus",
      author:          "Thomas Kadauke",
      frontend: {
        routes: {
          "mysql_db_browser/MysqlConnections" => "app/frontend/routes/MysqlConnections.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/mysql_db_browser.json" ]
      },
      routes: [
        {
          verb: "GET",
          path: "/api/v1/app/admin/mysql_connections",
          controller: "api/v1/app/admin/mysql_connections#index"
        },
        {
          verb: "POST",
          path: "/api/v1/app/admin/mysql_connections",
          controller: "api/v1/app/admin/mysql_connections#create"
        },
        {
          verb: "PATCH",
          path: "/api/v1/app/admin/mysql_connections/:id",
          controller: "api/v1/app/admin/mysql_connections#update"
        },
        {
          verb: "DELETE",
          path: "/api/v1/app/admin/mysql_connections/:id",
          controller: "api/v1/app/admin/mysql_connections#destroy"
        },
        {
          verb: "POST",
          path: "/api/v1/app/admin/mysql_connections/test",
          controller: "api/v1/app/admin/mysql_connections#test_connection"
        },
        {
          verb: "POST",
          path: "/api/v1/app/admin/mysql_connections/:id/test",
          controller: "api/v1/app/admin/mysql_connections#test_connection"
        },
        {
          verb: "GET",
          path: "/api/v1/app/admin/mysql_connections/:id/schema",
          controller: "api/v1/app/admin/mysql_schema#databases"
        },
        {
          verb: "GET",
          path: "/api/v1/app/admin/mysql_connections/:id/schema/:database/tables",
          controller: "api/v1/app/admin/mysql_schema#tables"
        },
        {
          verb: "GET",
          path: "/api/v1/app/admin/mysql_connections/:id/schema/:database/tables/:table",
          controller: "api/v1/app/admin/mysql_schema#show"
        },
        {
          verb: "GET",
          path: "/api/v1/app/admin/mysql_connections/:id/schema/:database/tables/:table/content",
          controller: "api/v1/app/admin/mysql_query#content"
        },
        {
          verb: "POST",
          path: "/api/v1/app/admin/mysql_connections/:id/query",
          controller: "api/v1/app/admin/mysql_query#execute"
        },
        {
          verb: "GET",
          path: "/api/v1/app/admin/mysql_connections/:id/schema/:database/query_builder",
          controller: "api/v1/app/admin/mysql_query#query_builder"
        }
      ],
      provides: {
        sidebar_page:      MysqlDbBrowser::SidebarPages,
        mcp_tool_set:      MysqlDbBrowser::WorkflowToolSet,
        chat_mcp_tool_set: MysqlDbBrowser::ChatToolSet
      }
    )
  end

  def self.enabled?
    Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "mysql_db_browser" && manifest.enabled? }
  end

  # The acting user to attribute an agent-issued query/tool call to, for
  # MysqlQueryAudit and any future audit surface. server_context's shape
  # differs by MCP surface: chat carries the ChatSession directly; workflow
  # carries a run_id (or run) resolved through Mcp::Tools.run_from_context.
  def self.user_from_server_context(server_context)
    if server_context[:chat_session]
      server_context[:chat_session].user
    else
      Mcp::Tools.run_from_context(server_context).job.user
    end
  end
end
