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
      homepage:        "https://github.com/tkadauke/syrus",
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
