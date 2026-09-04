module MysqlDbBrowser
  extend Syrus::PluginApi

  def self.user_from_server_context(server_context)
    if server_context[:chat_session]
      server_context[:chat_session].user
    else
      Mcp::Tools.run_from_context(server_context).job.user
    end
  end

  syrus_plugin "mysql_db_browser" do
    display_name "MySQL DB Browser"
    description "Register and manage connections to external MySQL databases with encrypted credential storage."
    long_description "MySQL DB Browser lets admins register external MySQL connections, inspect schemas, browse table contents, and run controlled queries from the Syrus admin UI. Credentials are stored encrypted and connections are explicit per database target.\n\nThis plugin is separate from Admin MySQL: Admin MySQL inspects Syrus' own runtime database, while MySQL DB Browser is for operator-managed external databases that Syrus may need to inspect."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/mysql_db_browser.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled false
    disableable true
    provides sidebar_page: "MysqlDbBrowser::SidebarPages",
             mcp_tool_set: "MysqlDbBrowser::WorkflowToolSet",
             chat_mcp_tool_set: "MysqlDbBrowser::ChatToolSet"
    route :get, "/api/v1/app/admin/mysql_connections", to: "api/v1/app/admin/mysql_connections#index"
    route :post, "/api/v1/app/admin/mysql_connections", to: "api/v1/app/admin/mysql_connections#create"
    route :patch, "/api/v1/app/admin/mysql_connections/:id", to: "api/v1/app/admin/mysql_connections#update"
    route :delete, "/api/v1/app/admin/mysql_connections/:id", to: "api/v1/app/admin/mysql_connections#destroy"
    route :post, "/api/v1/app/admin/mysql_connections/test", to: "api/v1/app/admin/mysql_connections#test_connection"
    route :post, "/api/v1/app/admin/mysql_connections/:id/test", to: "api/v1/app/admin/mysql_connections#test_connection"
    route :get, "/api/v1/app/admin/mysql_connections/:id/schema", to: "api/v1/app/admin/mysql_schema#databases"
    route :get, "/api/v1/app/admin/mysql_connections/:id/schema/:database/tables", to: "api/v1/app/admin/mysql_schema#tables"
    route :get, "/api/v1/app/admin/mysql_connections/:id/schema/:database/tables/:table", to: "api/v1/app/admin/mysql_schema#show"
    route :get, "/api/v1/app/admin/mysql_connections/:id/schema/:database/tables/:table/content", to: "api/v1/app/admin/mysql_query#content"
    route :post, "/api/v1/app/admin/mysql_connections/:id/query", to: "api/v1/app/admin/mysql_query#execute"
    route :get, "/api/v1/app/admin/mysql_connections/:id/schema/:database/query_builder", to: "api/v1/app/admin/mysql_query#query_builder"
    frontend routes: {
          "mysql_db_browser/MysqlConnections" => "app/frontend/routes/MysqlConnections.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/mysql_db_browser.json" ]
  end
end
