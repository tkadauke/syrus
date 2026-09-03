module AgentInsights
  class AdminPages
    include Syrus::Plugin::AdminPage

    def self.admin_pages
      [
        {
          id: "agent_insights.admin",
          label: "Insights",
          label_key: "agent_insights:nav_insights",
          path: "/admin/insights",
          paths: [ "/admin/insights" ],
          component: "agent_insights/AdminInsights",
          group_id: "product_data",
          order: 20
        }
      ]
    end
  end
end
