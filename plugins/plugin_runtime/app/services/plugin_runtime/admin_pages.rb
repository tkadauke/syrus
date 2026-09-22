module PluginRuntime
  class AdminPages
    include Syrus::Plugin::AdminPage

    def self.admin_pages
      [
        {
          id: "plugin_runtime.services",
          label: "Plugin Services",
          label_key: "plugin_runtime:nav_plugin_services",
          path: "/admin/plugin_services",
          paths: [ "/admin/plugin_services" ],
          component: "plugin_runtime/AdminPluginServices",
          group_id: "observability",
          order: 44
        }
      ]
    end
  end
end
