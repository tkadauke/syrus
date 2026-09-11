module GithubSource
  class AdminPages
    include Syrus::Plugin::AdminPage

    def self.admin_pages
      [
        {
          id: "github_source.api_usage",
          label: "GitHub API Usage",
          label_key: "github_source:nav_api_usage",
          path: "/admin/github_api_usage",
          paths: [ "/admin/github_api_usage" ],
          component: "github_source/AdminGithubApiUsage",
          group_id: "observability",
          order: 42
        }
      ]
    end
  end
end
