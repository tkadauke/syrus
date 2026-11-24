module MysqlDbBrowser
  class SidebarPages
    include Syrus::Host::SidebarPage

    def self.sidebar_pages
      return [] unless MysqlDbBrowser.enabled?
      return [] unless Syrus::Host::Current.user&.admin?

      [
        {
          id: "mysql_db_browser.connections",
          label: "DB Browser",
          label_key: "mysql_db_browser:nav_db_browser",
          path: "/db_browser",
          paths: [ "/db_browser" ],
          component: "mysql_db_browser/MysqlConnections",
          icon: "database",
          order: 70
        }
      ]
    end
  end
end
