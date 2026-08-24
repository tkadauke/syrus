require "mysql_db_browser/version"
require "mysql_db_browser/engine"

module MysqlDbBrowser
  def self.register!
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
        }
      ]
    )
  end

  def self.enabled?
    Feature.enabled?(:mysql_db_browser) &&
      Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "mysql_db_browser" && manifest.enabled? }
  end
end
