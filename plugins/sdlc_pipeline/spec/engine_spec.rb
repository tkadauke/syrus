require "rails_helper"

RSpec.describe SdlcPipeline::Engine do
  it "is an experimental, disableable plugin that is not enabled by default" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "sdlc_pipeline" }

    expect(manifest.experimental?).to be(true)
    expect(manifest.disableable?).to be(true)
    expect(manifest.default_enabled?).to be(false)
  end

  it "registers none of its providers or tools while disabled" do
    PluginRecord.find_by!(name: "sdlc_pipeline").update!(enabled: false)

    expect(Syrus::Plugin::Surface.contributions(:repo_page_tabs)).not_to include(SdlcPipeline::RepoPageTabs)
    expect(Syrus::Plugin::Toolkit.chat_tool_sets).not_to include(SdlcPipeline::ChatToolSet)
    expect(Syrus::Plugin::ChatIntegration.contributions(:job_status_extensions)).not_to include(SdlcPipeline::ChatJobStatusExtension)
  ensure
    PluginRecord.find_by!(name: "sdlc_pipeline").update!(enabled: true)
  end

  it "registers the repository tab and route" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "sdlc_pipeline" }

    expect(manifest).to be_present
    expect(manifest.family_provides.map(&:family)).to include(:surface, :chat_integration)
    expect(Syrus::Plugin::Surface.contributions(:repo_page_tabs)).to include(SdlcPipeline::RepoPageTabs)
    expect(Syrus::Plugin::Toolkit.chat_tool_sets).to include(SdlcPipeline::ChatToolSet)
    expect(Syrus::Plugin::ChatIntegration.contributions(:job_status_extensions)).to include(SdlcPipeline::ChatJobStatusExtension)
  end

  it "registers and retires the plugin-owned filter and SmartFolder subjects" do
    expect(Filters.subject(:sdlc_pipeline).fields).to contain_exactly("search", "associated_chat_id", "epic_id", "job_id", "owner_user_id")
    expect(SmartFolder.registered_subjects.fetch("sdlc_pipeline").fetch(:builtins).map { |row| row.fetch(:name) }).to eq([ "All", "Mine" ])

    PluginRecord.find_by!(name: "sdlc_pipeline").update!(enabled: false)
    expect(Filters.subjects).not_to have_key(:sdlc_pipeline)
    expect(SmartFolder.registered_subjects).not_to have_key("sdlc_pipeline")
    expect(Syrus::Plugin::Toolkit.chat_tool_sets).not_to include(SdlcPipeline::ChatToolSet)
    expect(Syrus::Plugin::ChatIntegration.contributions(:job_status_extensions)).not_to include(SdlcPipeline::ChatJobStatusExtension)
  ensure
    PluginRecord.find_by!(name: "sdlc_pipeline")&.update!(enabled: true)
  end
end
