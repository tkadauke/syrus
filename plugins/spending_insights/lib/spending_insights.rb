module SpendingInsights
  extend Syrus::PluginApi

  syrus_plugin "spending_insights" do
    display_name "Spending Insights"
    description "Agent spend dashboard (cost rollups by Epic, user, repository, and trigger kind) in the primary sidebar."
    long_description "Spending Insights adds a sidebar page for understanding agent spend across Syrus. It rolls costs up by epic, repository, user, provider, and workflow trigger so operators can see where automation budget is going.\n\nUse it on instances where cost visibility matters. It reads existing accounting data and does not change scheduling, grading, or job behavior."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/spending_insights.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled true
    disableable true
    provides sidebar_page: "SpendingInsights::SidebarPages",
             chat_mcp_tool_set: "SpendingInsights::ChatToolSet"
    route :get, "/api/v1/app/insights/spending", to: "api/v1/app/insights/spending#show"
    frontend routes: {
          "spending_insights/SpendingInsights" => "app/frontend/routes/SpendingInsights.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/spending.json" ]

    while_enabled do |scope|
      scope.effect("filter subjects") do
        Filters.register_subject(
          name: :spending_report,
          model: Run,
          chips: {
            "repository_id"  => "Filters::Chips::SpendingReport::RepositoryId",
            "user_id"        => "Filters::Chips::SpendingReport::UserId",
            "created_at"     => "Filters::Chips::SpendingReport::CreatedAt",
            "agent_provider" => "Filters::Chips::SpendingReport::AgentProvider",
            "trigger_kind"   => "Filters::Chips::SpendingReport::TriggerKind",
            "epic_id"        => "Filters::Chips::SpendingReport::EpicId"
          }
        )
      end
    end
  end
end
