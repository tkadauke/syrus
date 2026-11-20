require "rails_helper"

RSpec.describe ReviewWorkspace::Engine do
  it "registers a disableable bundled review plugin" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "review_workspace" }

    expect(manifest).to be_present
    expect(manifest.display_name).to eq("Review Workspace")
    expect(manifest.default_enabled?).to be(true)
    expect(manifest.disableable?).to be(true)
    expect(manifest.provides).to include(:sidebar_page)
  end
end
