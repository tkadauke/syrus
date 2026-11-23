module AgentActivity
  class AdminPages
    include Syrus::Host::AdminPage

    def self.admin_pages
      return [] unless AgentActivity.enabled?
      return [] unless Syrus::Host::Current.user&.admin?

      [
        {
          id: "agent_activity.admin",
          label: "Agent Activity",
          label_key: "agent_activity:nav_admin_agent_activity",
          path: "/admin/agent_activity",
          paths: [ "/admin/agent_activity" ],
          component: "agent_activity/AdminAgentActivity",
          group_id: "operations",
          order: 35
        }
      ]
    end
  end
end
