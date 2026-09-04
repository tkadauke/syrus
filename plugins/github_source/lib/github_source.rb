module SyrusGithubSource
  extend Syrus::PluginApi

  syrus_plugin "github_source" do
    display_name "GitHub Source"
    description "Ingests GitHub issues and provides GitHub PR operations."
    long_description "GitHub Source is Syrus' built-in GitHub integration. It polls issues and pull requests, opens and updates PRs, reads check state, performs landing operations, and supplies the source-control primitives other workflows rely on.\n\nFor most Syrus installations this is the default path for issue-to-PR automation, so it is enabled out of the box. It can be disabled once nothing depends on it: the disable guard blocks the attempt while any input source or active repository still uses it. Future source plugins can follow the same extension points."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/github_source.svg"
    author "Thomas Kadauke"
    category "input_source"
    default_enabled true
    disableable true
    provides repo_page_tab: "GithubSource::RepoPageTabs",
             input_source: "InputSources::Github",
             source_control_provider: "SourceControl::GithubOperations"
    route :get, "/api/v1/app/repositories/:repository_id/issues", to: "api/v1/app/repository_issues#issues"
    route :post, "/api/v1/app/repositories/:repository_id/issues/comment", to: "api/v1/app/repository_issues#comment_issue"
    route :post, "/api/v1/app/repositories/:repository_id/issues/close", to: "api/v1/app/repository_issues#close_issue"
    route :post, "/api/v1/app/repositories/:repository_id/issues/delegate", to: "api/v1/app/repository_issues#delegate_issue"
    route :post, "/api/v1/app/repositories/:repository_id/issues/bulk", to: "api/v1/app/repository_issues#bulk_issues"
    frontend routes: { "github_source/RepositoryIssues" => "app/frontend/repo_tabs/RepositoryIssues.tsx" },
        i18n: [ "app/frontend/i18n/locales/*/github_source.json" ]
  end
end
