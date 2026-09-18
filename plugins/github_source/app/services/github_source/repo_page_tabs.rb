module GithubSource
  class RepoPageTabs
    include Syrus::Plugin::RepoPageTab

    def self.repo_page_tabs(repository:, user:)
      return [] if repository.blank?

      [
        {
          id: "github_source.issues",
          label: "GitHub Issues",
          label_key: "github_source:tab_issues",
          path: "/repositories/#{repository.id}/plugin/issues",
          paths: [ "/repositories/#{repository.id}/plugin/issues" ],
          component: "github_source/RepositoryIssues",
          order: 2
        }
      ]
    end
  end
end
