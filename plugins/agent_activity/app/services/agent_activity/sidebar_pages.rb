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
          # AgentActivity::SmartFolders::BUILTINS already registers its own
          # unfiltered "All" folder, so the sidebar's generic "All agent
          # activity" catch-all link would just duplicate it -- and, worse,
          # its unfiltered path silently falls back to the default "Running"
          # folder server-side instead of actually showing everything.
          smart_folder_all_link: false,
          order: 35
        }
      ]
    end
  end
end
