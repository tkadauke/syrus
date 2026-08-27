require "admin_mysql/version"
require "admin_mysql/engine"

module AdminMysql
  def self.register!
    AdminMysql::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet) unless AdminMysql::ChatToolSet < Syrus::Plugin::ChatMcpToolSet
    AdminMysql::AdminPages.include(Syrus::Plugin::AdminPage) unless AdminMysql::AdminPages < Syrus::Plugin::AdminPage

    Syrus::PluginRegistry.register(
      name:            "admin_mysql",
      display_name:    "Admin MySQL",
      version:         AdminMysql::VERSION,
      default_enabled: false,
      disableable:     true,
      category:        "observability",
      description:     "Live MySQL diagnostics for production operators.",
      long_description: "Admin MySQL exposes the live state of a Syrus instance's MySQL server: process list, connection pressure, slow-log configuration, statement digests, and targeted query termination. It is intentionally operator-facing and disabled by default because it surfaces database internals and control actions.\n\nUse this plugin when a deployment runs against MySQL and needs real-time production diagnosis without shelling into the database pod. SQLite-backed installations do not need it.",
      homepage:        "https://github.com/tkadauke/syrus",
      icon_url:        "/plugin-icons/admin_mysql.svg",
      author:          "Thomas Kadauke",
      frontend: {
        routes: {
          "admin_mysql/AdminMysql" => "app/frontend/routes/AdminMysql.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/admin_mysql.json" ]
      },
      routes: [
        {
          verb: "GET",
          path: "/api/v1/app/admin/mysql",
          controller: "api/v1/app/admin/mysql#show"
        },
        {
          verb: "POST",
          path: "/api/v1/app/admin/mysql/kill_query",
          controller: "api/v1/app/admin/mysql#kill_query"
        },
        {
          verb: "GET",
          path: "/api/v1/admin/mysql",
          controller: "api/v1/admin/mysql#show"
        },
        {
          verb: "POST",
          path: "/api/v1/admin/mysql/kill_query",
          controller: "api/v1/admin/mysql#kill_query"
        },
        {
          verb: "GET",
          path: "/admin/mysql",
          controller: "spa#show"
        }
      ],
      provides: {
        admin_page:        AdminMysql::AdminPages,
        mcp_tool_set:      AdminMysql::WorkflowToolSet,
        chat_mcp_tool_set: AdminMysql::ChatToolSet
      }
    )
  end

  def self.enabled?
    Syrus::PluginRegistry.providers_for(:admin_page).include?(AdminPages)
  end

  def self.mysql?
    Inspector.mysql?
  end
end
