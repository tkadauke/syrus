module AdminMysql
  extend Syrus::PluginApi

  def self.mysql?
    Inspector.mysql?
  end

  syrus_plugin "admin_mysql" do
    capability_descriptor_compatibility chat_mcp_tool_set: "5c7d6aecd086ecd7618ec2d000b3a5ce820dcbac86782d1b45837e1bf11db4a1", mcp_tool_set: "e17abbfab94813817e7dd9a698d5ecb48a9576cd67c38ae7f8bb668f9b07b09c"
    experimental true
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
