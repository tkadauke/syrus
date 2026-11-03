module SdlcPipeline
  extend Syrus::PluginApi

  syrus_plugin "sdlc_pipeline" do
    capability_descriptor_compatibility chat_mcp_tool_set: "a141fbece18b215cff90c6bb771f51f009f8cbf18c1506947dca7f319630d853"
    display_name "SDLC Pipeline"
    category "collaboration"
    author "Thomas Kadauke"
    icon_url "/plugin-icons/sdlc_pipeline.svg"
    description "A bounded repository pipeline derived from existing lifecycle and deployment facts."
    long_description "SDLC Pipeline turns the existing Job, Epic, landing, and deployment-stage records into an ordered repository view. It is a read-only projection: disabling or removing the plugin does not change delivery state."

    provides repo_page_tab: "SdlcPipeline::RepoPageTabs",
             chat_mcp_tool_set: "SdlcPipeline::ChatToolSet",
             chat_job_status_extension: "SdlcPipeline::ChatJobStatusExtension"
    route :get, "/api/v1/app/repositories/:repository_id/sdlc_pipeline",
          to: "api/v1/app/repository_sdlc_pipeline#show"

    frontend routes: { "sdlc_pipeline/RepositoryPipeline" => "app/frontend/repo_tabs/RepositoryPipeline.tsx" },
             i18n: [ "app/frontend/i18n/locales/*/sdlc_pipeline.json" ]

    while_enabled do |scope|
      SdlcPipeline::SmartFolders.install_into(scope)
    end
  end
end
