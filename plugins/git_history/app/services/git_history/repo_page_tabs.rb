module GitHistory
  class RepoPageTabs
    def self.repo_page_tabs(repository:, user:)
      return [] unless Repository.accessible_to(user).exists?(id: repository.id)

      [
        {
          id: "git_history.git_history",
          label: "Git History",
          label_key: "git_history:nav_git_history",
          path: "/repositories/#{repository.id}/plugin/git_history",
          # PluginRouteResolver#repo_page_tab_route? matches on `paths`, and it
          # is what gates the "repositories/:repository_id/plugin/*path"
          # wildcard -- so a tab that declares only `path` 404s on hard
          # reload. That is the exact bug this extension point was built to
          # prevent, and this tab still had it.
          paths: [ "/repositories/#{repository.id}/plugin/git_history" ],
          component: "git_history/GitHistory",
          order: 40
        }
      ]
    end
  end
end
