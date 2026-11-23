module LocalBackups
  class AdminPages
    include Syrus::Host::AdminPage

    def self.admin_pages
      [{
        id: "local_backups.admin", label: "Local Backups", label_key: "local_backups:nav_local_backups",
        path: "/admin/local_backups", paths: ["/admin/local_backups"],
        component: "local_backups/AdminLocalBackups", group_id: "operations", order: 75
      }]
    end
  end
end
