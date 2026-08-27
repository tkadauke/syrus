module SyrusDev
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "syrus_dev",
        display_name:    "Syrus Dev",
        version:         SyrusDev::VERSION,
        default_enabled: false,
        disableable:     true,
        category:        "tooling",
        description:     "Syrus development diagnostics and internal tooling.",
        long_description: "Syrus Dev contains tooling that is useful when developing Syrus itself: performance diagnostics, operational logs, admin observability pages, and workflow MCP helpers that expose Syrus runtime data to Syrus-development jobs.\n\nKeep this plugin disabled on ordinary installations unless operators explicitly want Syrus-internal diagnostics. It is not a general admin plugin; it exists to make Syrus better at building and debugging Syrus.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/syrus_dev.svg",
        author:          "Thomas Kadauke",
        frontend: {
          routes: {
            "syrus_dev/AdminPerformance" => "app/frontend/routes/AdminPerformance.tsx",
            "syrus_dev/AdminOperationalLogs" => "app/frontend/routes/AdminOperationalLogs.tsx"
          },
          i18n: [ "app/frontend/i18n/locales/*/syrus_dev.json" ]
        },
        routes: [
          {
            verb: "GET",
            path: "/api/v1/app/admin/performance",
            controller: "api/v1/app/admin/performance#show"
          },
          {
            verb: "POST",
            path: "/api/v1/app/admin/performance/explain",
            controller: "api/v1/app/admin/performance#explain"
          },
          {
            verb: "GET",
            path: "/api/v1/app/admin/operational_logs",
            controller: "api/v1/app/admin/operational_logs#index"
          },
          {
            verb: "GET",
            path: "/api/v1/admin/performance",
            controller: "api/v1/admin/performance#show"
          },
          {
            verb: "POST",
            path: "/api/v1/admin/performance/explain",
            controller: "api/v1/admin/performance#explain"
          },
          {
            verb: "GET",
            path: "/api/v1/admin/operational_logs",
            controller: "api/v1/admin/operational_logs#index"
          },
          {
            verb: "GET",
            path: "/admin/performance",
            controller: "spa#show"
          },
          {
            verb: "GET",
            path: "/admin/operational_logs",
            controller: "spa#show"
          }
        ],
        provides: {
          admin_page:   SyrusDev::AdminPages,
          mcp_tool_set: SyrusDev::WorkflowToolSet
        }
      )
    end
  end
end
