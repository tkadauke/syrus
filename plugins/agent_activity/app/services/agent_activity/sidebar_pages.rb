module AgentActivity
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      return [] unless AgentActivity.enabled?
      return [] unless Current.user

      pages = [
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

      if Current.user.admin?
        pages << {
          id: "agent_activity.admin",
          label: "Agent Activity",
          label_key: "agent_activity:nav_admin_agent_activity",
          path: "/admin/agent_activity",
          paths: [ "/admin/agent_activity" ],
          component: "agent_activity/AdminAgentActivity",
          icon: "activity",
          order: 81
        }
      end

      pages
    end
  end
end
