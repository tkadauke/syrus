require "rails_helper"

RSpec.describe Throughput::Engine do
  it "is registered and enabled by default" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "throughput" }

    expect(manifest).to be_present
    expect(manifest.enabled?).to be(true)
    expect(Syrus::PluginRegistry.providers_for(:ui_slot)).to include(Throughput::UiSlots)
  end

  it "samples landing throughput on the plugin tick, which only fires while enabled" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "throughput" }

    expect(manifest.tick_interval).to eq(1.minute)
    expect(Array(manifest.provides[:callbacks])).to include(Throughput::Callbacks)
  end

  # Plugin metrics follow while_enabled semantics: a disabled plugin emits no
  # series at all. The declaration is a Syrus::Installer while_enabled effect,
  # which is sync-on-read (see MetricsController#sync_plugin_declarations)
  # rather than reapplied on a timer, so the test drives that sync explicitly.
  it "declares its landing throughput metrics only while enabled" do
    PluginRecord.find_or_create_by!(name: "throughput") { |record| record.enabled = true }
    Syrus::Installer.sync!
    expect(Syrus::Metrics.registry.declared?(:syrus_throughput_landing_units_total)).to be(true)
    expect(Syrus::Metrics.registry.declared?(:syrus_throughput_jobs_landed_total)).to be(true)

    PluginRecord.find_by!(name: "throughput").update!(enabled: false)
    Syrus::Installer.sync!
    expect(Syrus::Metrics.registry.declared?(:syrus_throughput_landing_units_total)).to be(false)
    expect(Syrus::Metrics.registry.declared?(:syrus_throughput_jobs_landed_total)).to be(false)

    PluginRecord.find_by!(name: "throughput").update!(enabled: true)
    Syrus::Installer.sync!
    expect(Syrus::Metrics.registry.declared?(:syrus_throughput_landing_units_total)).to be(true)
  end
end
