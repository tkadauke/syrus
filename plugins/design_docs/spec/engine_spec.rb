require "rails_helper"

RSpec.describe DesignDocs::Engine do
  it "is registered enabled by default for the standard bundled-plugin test setup" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "design_docs" }

    expect(manifest).to be_present
    expect(manifest.display_name).to eq("Design Docs")
    expect(manifest.default_enabled?).to be(true)
    expect(manifest.enabled?).to be(true)
    expect(manifest.disableable?).to be(true)
  end

  it "is treated as enabled on a fresh install with no prior PluginRecord row", :reset_plugin_registry do
    Syrus::PluginRegistry.reset!
    PluginRecord.where(name: "design_docs").delete_all

    DesignDocs.register!

    expect(PluginRecord.find_by!(name: "design_docs").enabled?).to be(true)

    Syrus::PluginRegistry.reset!
  end
end
