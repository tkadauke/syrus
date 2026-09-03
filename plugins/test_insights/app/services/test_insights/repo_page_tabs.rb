module TestInsights
  class RepoPageTabs
    include Syrus::Plugin::RepoPageTab

    # Hidden in simple mode, as the core tab was: flaky-test triage is a
    # developer surface, not something a non-technical operator watches.
    def self.repo_page_tabs(repository:, user:)
      return [] if AppSetting.simple?
      return [] if repository.blank?

      [
        {
          id: "test_insights.tests",
          label: "Tests",
          label_key: "test_insights:tab_tests",
          path: "/repositories/#{repository.id}/plugin/tests",
          paths: [ "/repositories/#{repository.id}/plugin/tests" ],
          component: "test_insights/RepositoryTests",
          order: 3
        }
      ]
    end
  end
end
