require "rails_helper"

RSpec.describe SdlcPipeline::Engine do
  it "registers the repository tab and route" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "sdlc_pipeline" }

    expect(manifest).to be_present
    expect(manifest.provides[:repo_page_tab]).to eq(SdlcPipeline::RepoPageTabs)
    expect(Syrus::PluginRegistry.providers_for(:repo_page_tab)).to include(SdlcPipeline::RepoPageTabs)
    expect(Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set)).to include(SdlcPipeline::ChatToolSet)
    expect(Syrus::PluginRegistry.providers_for(:chat_job_status_extension)).to include(SdlcPipeline::ChatJobStatusExtension)
  end

  it "registers and retires the plugin-owned filter and SmartFolder subjects" do
    expect(Filters.subject(:sdlc_pipeline).fields).to contain_exactly("search", "associated_chat_id", "epic_id", "job_id", "owner_user_id")
    expect(SmartFolder.registered_subjects.fetch("sdlc_pipeline").fetch(:builtins).map { |row| row.fetch(:name) }).to eq([ "All", "Mine" ])

    PluginRecord.find_by!(name: "sdlc_pipeline").update!(enabled: false)
    expect(Filters.subjects).not_to have_key(:sdlc_pipeline)
    expect(SmartFolder.registered_subjects).not_to have_key("sdlc_pipeline")
    expect(Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set)).not_to include(SdlcPipeline::ChatToolSet)
    expect(Syrus::PluginRegistry.providers_for(:chat_job_status_extension)).not_to include(SdlcPipeline::ChatJobStatusExtension)
  ensure
    PluginRecord.find_by!(name: "sdlc_pipeline")&.update!(enabled: true)
  end
end
