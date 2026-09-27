module OperatorBriefing
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      [
        {
          id: "operator_briefing.dashboard",
          label: "Briefing",
          label_key: "operator_briefing:nav_briefing",
          path: "/briefing",
          paths: [ "/briefing", "/briefing/history" ],
          component: "operator_briefing/Briefing",
          icon: "operator_briefing",
          order: 45
        }
      ]
    end
  end
end
