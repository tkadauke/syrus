module AdminMysql
  class AdminPages
    def self.admin_pages
      return [] unless AdminMysql.mysql?

      [
        {
          id: "admin_mysql.mysql",
          label: "MySQL",
          label_key: "admin_mysql:nav_mysql",
          path: "/admin/mysql",
          paths: [ "/admin/mysql" ],
          component: "admin_mysql/AdminMysql",
          group_id: "observability",
          order: 70
        }
      ]
    end
  end
end
