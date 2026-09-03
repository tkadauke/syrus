module SyrusGithubSource
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "github_source",
        display_name:    "GitHub Source",
        version:         SyrusGithubSource::VERSION,
        description:     "Ingests GitHub issues and provides GitHub PR operations.",
        long_description: "GitHub Source is Syrus' built-in GitHub integration. It polls issues and pull requests, opens and updates PRs, reads check state, performs landing operations, and supplies the source-control primitives other workflows rely on.\n\nFor most Syrus installations this is the default path for issue-to-PR automation, so it is enabled out of the box. It can be disabled once nothing depends on it: the disable guard blocks the attempt while any input source or active repository still uses it. Future source plugins can follow the same extension points.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/github_source.svg",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     true,
        category:        "input_source",
        frontend: {
          routes: { "github_source/RepositoryIssues" => "app/frontend/repo_tabs/RepositoryIssues.tsx" },
          i18n: [ "app/frontend/i18n/locales/*/github_source.json" ]
        },
        routes: [
          { verb: "GET",  path: "/api/v1/app/repositories/:repository_id/issues", controller: "api/v1/app/repository_issues#issues" },
          { verb: "POST", path: "/api/v1/app/repositories/:repository_id/issues/comment", controller: "api/v1/app/repository_issues#comment_issue" },
          { verb: "POST", path: "/api/v1/app/repositories/:repository_id/issues/close", controller: "api/v1/app/repository_issues#close_issue" },
          { verb: "POST", path: "/api/v1/app/repositories/:repository_id/issues/delegate", controller: "api/v1/app/repository_issues#delegate_issue" },
          { verb: "POST", path: "/api/v1/app/repositories/:repository_id/issues/bulk", controller: "api/v1/app/repository_issues#bulk_issues" }
        ],
        provides: {
          repo_page_tab:           GithubSource::RepoPageTabs,
          input_source:            InputSources::Github,
          source_control_provider: SourceControl::GithubOperations
        }
      )
    end
  end
end
