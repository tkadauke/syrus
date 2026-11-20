module ReviewWorkspacePlugin
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      [
        {
          id: "review_workspace.review",
          label: "Review",
          label_key: "review_workspace:nav_review",
          path: "/review",
          paths: [ "/review", "/review/:job_id" ],
          component: "review_workspace/ReviewWorkspace",
          icon: "document",
          badge_api_path: "/api/v1/app/review_workspace/count",
          order: 15
        }
      ]
    end
  end
end
