module AdminMysql
  extend Syrus::PluginApi

  def self.mysql?
    Inspector.mysql?
  end

  syrus_plugin "admin_mysql" do
    display_name "Admin MySQL"
    description "Live MySQL diagnostics for production operators."
    long_description "Admin MySQL exposes the live state of a Syrus instance's MySQL server: process list, connection pressure, slow-log configuration, statement digests, and targeted query termination. It is intentionally operator-facing and disabled by default because it surfaces database internals and control actions.\n\nUse this plugin when a deployment runs against MySQL and needs real-time production diagnosis without shelling into the database pod. SQLite-backed installations do not need it."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/admin_mysql.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled false
    disableable true

    suggests_enabling "This instance is configured against MySQL, so live process list, connection pressure, and statement digests are available without shelling into the database." do |signals|
      signals.database_adapters.grep(/mysql/i).presence
    end

    provides admin_page: "AdminMysql::AdminPages",
             mcp_tool_set: "AdminMysql::WorkflowToolSet",
             chat_mcp_tool_set: "AdminMysql::ChatToolSet"
    route :get, "/api/v1/app/admin/mysql", to: "api/v1/app/admin/mysql#show"
    route :post, "/api/v1/app/admin/mysql/kill_query", to: "api/v1/app/admin/mysql#kill_query"
    route :get, "/api/v1/admin/mysql", to: "api/v1/admin/mysql#show"
    route :post, "/api/v1/admin/mysql/kill_query", to: "api/v1/admin/mysql#kill_query"
    route :get, "/admin/mysql", to: "spa#show"
    frontend routes: {
          "admin_mysql/AdminMysql" => "app/frontend/routes/AdminMysql.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/admin_mysql.json" ]
  end
end
