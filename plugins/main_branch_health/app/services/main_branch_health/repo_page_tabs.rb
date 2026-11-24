module MainBranchHealth
  class RepoPageTabs
    include Syrus::Plugin::RepoPageTab

    def self.repo_page_tabs(repository:, user:)
      return [] unless Repository.accessible_to(user).exists?(id: repository.id)

      path = "/repositories/#{repository.id}/health"
      [
        {
          id: "health",
          label: I18n.t("api.repositories.tabs.health"),
          label_key: "main_branch_health:tab_health",
          path: path,
          paths: [ path ],
          component: "main_branch_health/RepositoryHealth",
          order: 1,
          badge: repository.main_health_broken? ? "!" : nil
        }
      ]
    end
  end
end
