module SdlcPipeline
  extend Syrus::PluginApi

  syrus_plugin "sdlc_pipeline" do
    display_name "SDLC Pipeline"
    category "collaboration"
    author "Thomas Kadauke"
    description "A bounded repository pipeline derived from existing lifecycle and deployment facts."
    long_description "SDLC Pipeline turns the existing Job, Epic, landing, and deployment-stage records into an ordered repository view. It is a read-only projection: disabling or removing the plugin does not change delivery state."

    provides repo_page_tab: "SdlcPipeline::RepoPageTabs"
    route :get, "/api/v1/app/repositories/:repository_id/sdlc_pipeline",
          to: "api/v1/app/repository_sdlc_pipeline#show"

    frontend routes: { "sdlc_pipeline/RepositoryPipeline" => "app/frontend/repo_tabs/RepositoryPipeline.tsx" },
             i18n: [ "app/frontend/i18n/locales/*/sdlc_pipeline.json" ]
  end
end
