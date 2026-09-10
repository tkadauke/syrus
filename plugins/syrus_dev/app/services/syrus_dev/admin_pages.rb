module SyrusDev
  class AdminPages
    include Syrus::Plugin::AdminPage

    def self.admin_pages
      pages = [
        {
          id: "syrus_dev.performance",
          label: "Performance",
          label_key: "syrus_dev:nav_performance",
          path: "/admin/performance",
          paths: [ "/admin/performance" ],
          component: "syrus_dev/AdminPerformance",
          group_id: "observability",
          order: 40
        },
        {
          id: "syrus_dev.operational_logs",
          label: "Operational Logs",
          label_key: "syrus_dev:nav_operational_logs",
          path: "/admin/operational_logs",
          paths: [ "/admin/operational_logs" ],
          component: "syrus_dev/AdminOperationalLogs",
          group_id: "observability",
          order: 45
        },
        {
          id: "syrus_dev.design_system",
          label: "Design System",
          label_key: "syrus_dev:nav_design_system",
          path: "/admin/design_system",
          paths: [ "/admin/design_system" ],
          component: "syrus_dev/AdminDesignSystem",
          group_id: "development",
          order: 90
        }
      ]

      pages.reject! { |page| page[:id] == "syrus_dev.operational_logs" } unless OperationalLogging.enabled_for_instance?
      pages
    end
  end
end
