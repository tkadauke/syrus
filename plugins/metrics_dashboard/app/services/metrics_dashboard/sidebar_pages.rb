module MetricsDashboard
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      [
        {
          id: "metrics_dashboard.index",
          label: "Metrics",
          path: "/metrics_dashboard",
          # `paths` is the whole contract: React registers a route per entry and
          # PluginRouteResolver answers Rails' SPA wildcard from the same list,
          # so a path missing here renders the bare bootstrap shell on direct
          # navigation -- silently, because Rails still serves the shell.
          paths: [ "/metrics_dashboard" ],
          component: "metrics_dashboard/MetricsDashboard",
          icon: "chart",
          order: 72
        }
      ]
    end
  end
end
