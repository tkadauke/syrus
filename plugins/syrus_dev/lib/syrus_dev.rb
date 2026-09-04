module SyrusDev
  extend Syrus::PluginApi

  syrus_plugin "syrus_dev" do
    display_name "Syrus Dev"
    description "Syrus development diagnostics and internal tooling."
    long_description "Syrus Dev contains tooling that is useful when developing Syrus itself: performance diagnostics, operational logs, admin observability pages, and workflow MCP helpers that expose Syrus runtime data to Syrus-development jobs.\n\nKeep this plugin disabled on ordinary installations unless operators explicitly want Syrus-internal diagnostics. It is not a general admin plugin; it exists to make Syrus better at building and debugging Syrus."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/syrus_dev.svg"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled false
    disableable true
    provides admin_page: "SyrusDev::AdminPages",
             mcp_tool_set: "SyrusDev::WorkflowToolSet"
    route :get, "/api/v1/app/admin/performance", to: "api/v1/app/admin/performance#show"
    route :post, "/api/v1/app/admin/performance/explain", to: "api/v1/app/admin/performance#explain"
    route :get, "/api/v1/app/admin/operational_logs", to: "api/v1/app/admin/operational_logs#index"
    route :get, "/api/v1/admin/performance", to: "api/v1/admin/performance#show"
    route :post, "/api/v1/admin/performance/explain", to: "api/v1/admin/performance#explain"
    route :get, "/api/v1/admin/operational_logs", to: "api/v1/admin/operational_logs#index"
    route :get, "/admin/performance", to: "spa#show"
    route :get, "/admin/operational_logs", to: "spa#show"
    frontend routes: {
          "syrus_dev/AdminPerformance" => "app/frontend/routes/AdminPerformance.tsx",
          "syrus_dev/AdminOperationalLogs" => "app/frontend/routes/AdminOperationalLogs.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/syrus_dev.json" ]
  end
end
