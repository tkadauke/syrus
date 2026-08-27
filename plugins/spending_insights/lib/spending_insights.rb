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
      provides: {
        sidebar_page: SpendingInsights::SidebarPages
      }
    )
  end
end
