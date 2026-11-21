require "rails_helper"

RSpec.describe ReviewWorkspacePlugin::Engine do
  it "registers a disableable bundled review plugin" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "review_workspace" }

    expect(manifest).to be_present
    expect(manifest.display_name).to eq("Review Workspace")
    expect(manifest.default_enabled?).to be(true)
    expect(manifest.disableable?).to be(true)
    expect(manifest.provides).to include(:sidebar_page, :ui_slot)
  end

  it "keeps its Ruby namespace distinct from the core review workspace" do
    manifest = Admin::PluginSourceBoundaryAudit.bundled_manifests.find { |plugin| plugin.name == "review_workspace" }

    expect(manifest.constants).to include("ReviewWorkspacePlugin")
    expect(manifest.constants).not_to include("ReviewWorkspace")
  end
end
