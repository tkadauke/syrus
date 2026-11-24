module SdlcPipeline
  class RepoPageTabs
    include Syrus::Host::RepoPageTab

    def self.repo_page_tabs(repository:, user:)
      return [] unless Syrus::Host::RepositoryRecord.accessible_to(user).exists?(id: repository.id)

      path = "/repositories/#{repository.id}/plugin/sdlc-pipeline"
      [ {
        id: "sdlc_pipeline.repository",
        label: I18n.t("sdlc_pipeline.tabs.pipeline"),
        label_key: "sdlc_pipeline:tab_pipeline",
        path: path,
        paths: [ path ],
        component: "sdlc_pipeline/RepositoryPipeline",
        order: 40
      } ]
    end
  end
end
