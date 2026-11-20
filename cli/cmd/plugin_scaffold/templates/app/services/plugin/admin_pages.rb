require "syrus/host/admin_page"

module {{MODULE_NAME}}
  class AdminPages
    include Syrus::Host::AdminPage

    def self.admin_pages
      [ { id: "{{PLUGIN_NAME}}.overview", label: "{{DISPLAY_NAME}}", path: "/admin/{{PLUGIN_NAME}}",
          paths: [ "/admin/{{PLUGIN_NAME}}" ], component: "{{PLUGIN_NAME}}/AdminExample", group_id: "system", order: 100 } ]
    end
  end
end
