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
          smart_folder_api_path: "/api/v1/app/agent_activity/sessions",
          smart_folder_subject: AgentActivity::SmartFolders::SUBJECT,
          order: 35
        }
      ]
    end
  end
end
