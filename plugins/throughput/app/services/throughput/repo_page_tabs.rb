module Throughput
  class RepoPageTabs
    include Syrus::Plugin::RepoPageTab

    def self.repo_page_tabs(repository:, user:)
      return [] unless Repository.accessible_to(user).exists?(id: repository.id)

      path = "/repositories/#{repository.id}/plugin/throughput"
      [
        {
          id: "throughput.repository",
          label: "Throughput",
          label_key: "throughput:tab_throughput",
          path: path,
          # React derives its client-side route from `paths`, not `path` --
          # so a tab that declares only `path` reaches the SPA shell on hard
          # reload (the host's blanket route covers that) but renders nothing,
          # because React has no route for it.
          paths: [ path ],
          component: "throughput/RepositoryThroughput",
          order: 45
        }
      ]
    end
  end
end
