module SdlcPipeline
  class RepoPageTabs
    include Syrus::Plugin::RepoPageTab

    def self.repo_page_tabs(repository:, user:)
      return [] unless Repository.accessible_to(user).exists?(id: repository.id)

      path = "/repositories/#{repository.id}/plugin/sdlc-pipeline"
      [ {
        id: "sdlc_pipeline.repository",
        label: I18n.t("sdlc_pipeline.tab_pipeline"),
        label_key: "sdlc_pipeline:tab_pipeline",
        path: path,
        paths: [ path ],
        component: "sdlc_pipeline/RepositoryPipeline",
        order: 40
      } ]
    end
  end
end
