require "rails_helper"

RSpec.describe AttentionReport::Engine do
  it "registers an optional observability plugin disabled by default" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "attention_report" }

    expect(manifest).to be_present
    expect(manifest.display_name).to eq("Attention Report")
    expect(manifest.category).to eq("observability")
    expect(manifest.default_enabled?).to be(false)
    expect(manifest.disableable?).to be(true)
  end
end
