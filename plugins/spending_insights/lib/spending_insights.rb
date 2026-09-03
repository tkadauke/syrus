require "spending_insights/version"
require "spending_insights/engine"

module SpendingInsights
  def self.register!
    Syrus::PluginRegistry.register(
      name:            "spending_insights",
      display_name:    "Spending Insights",
      version:         SpendingInsights::VERSION,
      default_enabled: true,
      disableable:     true,
      category:        "observability",
      description:     "Agent spend dashboard (cost rollups by Epic, user, repository, and trigger kind) in the primary sidebar.",
      long_description: "Spending Insights adds a sidebar page for understanding agent spend across Syrus. It rolls costs up by epic, repository, user, provider, and workflow trigger so operators can see where automation budget is going.\n\nUse it on instances where cost visibility matters. It reads existing accounting data and does not change scheduling, grading, or job behavior.",
      homepage:        "https://github.com/tkadauke/syrus",
      icon_url:        "/plugin-icons/spending_insights.svg",
      author:          "Thomas Kadauke",
      frontend: {
        routes: {
          "spending_insights/SpendingInsights" => "app/frontend/routes/SpendingInsights.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/spending.json" ]
      },
      routes: [
        {
          verb: "GET",
          path: "/api/v1/app/insights/spending",
          controller: "api/v1/app/insights/spending#show"
        }
      ],
      provides: {
        sidebar_page:      SpendingInsights::SidebarPages,
        chat_mcp_tool_set: SpendingInsights::ChatToolSet
      }
    )

    # The spending FilterBar subject lives with the plugin that serves it.
    # Registered here rather than in core's Filters::Registry so disabling the
    # plugin also retires its filter vocabulary.
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

  def self.enabled?
    Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "spending_insights" && manifest.enabled? }
  end
end
