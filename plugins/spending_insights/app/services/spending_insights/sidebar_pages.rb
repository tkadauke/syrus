module SpendingInsights
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      [
        {
          id: "spending.dashboard",
          label: "Spending",
          label_key: "spending:nav_spending",
          path: "/insights/spending",
          paths: [ "/insights/spending" ],
          component: "spending_insights/SpendingInsights",
          icon: "spending",
          order: 60
        }
      ]
    end
  end
end
