module DesignDocs
  class RepoPageTabs
    include Syrus::Plugin::RepoPageTab

    def self.repo_page_tabs(repository:, user:)
      return [] unless Repository.accessible_to(user).exists?(id: repository.id)

      count = DesignDoc.visible_to(user).joins(:design_doc_repositories)
        .where(design_doc_repositories: { repository_id: repository.id })
        .count

      [
        {
          id: "design_docs.repository",
          label: "Design Docs",
          path: "/repositories/#{repository.id}/plugin/design_docs",
          # React derives its client-side route from `paths`, not `path` --
          # so a tab that declares only `path` reaches the SPA shell on hard
          # reload (the host's blanket route covers that) but renders nothing,
          # because React has no route for it. That is the exact bug this
          # extension point was built to prevent, and this tab still had it.
          paths: [ "/repositories/#{repository.id}/plugin/design_docs" ],
          component: "design_docs/RepositoryDesignDocs",
          order: 35,
          badge: count.positive? ? count : nil
        }
      ]
    end
  end
end
