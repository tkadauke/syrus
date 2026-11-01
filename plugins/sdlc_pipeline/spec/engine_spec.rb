require "rails_helper"

RSpec.describe SdlcPipeline::Engine do
  it "registers the repository tab and route" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "sdlc_pipeline" }

    expect(manifest).to be_present
    expect(manifest.provides[:repo_page_tab]).to eq(SdlcPipeline::RepoPageTabs)
    expect(Syrus::PluginRegistry.providers_for(:repo_page_tab)).to include(SdlcPipeline::RepoPageTabs)
  end
end
