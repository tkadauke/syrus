module AgentActivity
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      return [] unless AgentActivity.enabled?
      return [] unless Current.user

      [
        {
          id: "agent_activity.mine",
          label: "Agent Activity",
          label_key: "agent_activity:nav_agent_activity",
          path: "/agent_activity",
          paths: [ "/agent_activity" ],
          component: "agent_activity/AgentActivity",
          icon: "activity",
          order: 35
        }
      ]
    end
  end
end
