module AttentionReport
  extend Syrus::PluginApi

  syrus_plugin "attention_report" do
    display_name "Attention Report"
    category "observability"
    author "Thomas Kadauke"
    icon_url "/plugin-icons/attention_report.svg"
    description "Per-user estimates of deciding, judging, and avoidable operator attention."
    long_description "Attention Report classifies existing Syrus activity into deciding, judging, and wasted-attention signals for the signed-in operator. It also reports active page-time statistics, agent runtime, and queue wait without pretending those machine times are human attention."
    default_enabled false
    disableable true

    provides sidebar_page: "AttentionReport::SidebarPages"
    route :get, "/api/v1/app/insights/attention", to: "api/v1/app/insights/attention#show"
    frontend routes: {
          "attention_report/AttentionReport" => "app/frontend/routes/AttentionReport.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/attention_report.json" ]
  end
end
