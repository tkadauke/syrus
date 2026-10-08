require "rails_helper"

RSpec.describe AlertmanagerInvestigations::Engine do
  it "registers the plugin disabled by default with a tick callback" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "alertmanager_investigations" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to eq(false)
    expect(manifest.tick_interval).to eq(1.minute)
    expect(Array(manifest.provides[:callbacks])).to include(AlertmanagerInvestigations::Callbacks)
    expect(manifest.config_schema.map { |entry| entry[:key] }).to include("base_url", "rate_limit_minutes", "host_label")
  end
end
