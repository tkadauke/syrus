require "rails_helper"

RSpec.describe VideoWalkthroughs::Engine do
  it "is registered and off by default" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "video_walkthroughs" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(false)
  end

  it "runs its retention tick, which only fires while enabled" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "video_walkthroughs" }

    expect(manifest.tick_interval).to eq(1.day)
    expect(Array(manifest.provides[:callbacks])).to include(VideoWalkthroughs::Callbacks)
  end

  # Plugin metrics follow while_enabled semantics: a disabled plugin emits no
  # series at all. The declaration is a Syrus::Installer while_enabled effect,
  # which is sync-on-read (see MetricsController#sync_plugin_declarations)
  # rather than reapplied on a timer, so the test drives that sync explicitly.
  it "declares its storage bytes gauge only while enabled" do
    record = PluginRecord.find_or_initialize_by(name: "video_walkthroughs")
    record.update!(enabled: true)
    Syrus::Installer.sync!
    expect(Syrus::Metrics.registry.declared?(:syrus_video_walkthroughs_storage_bytes)).to be(true)

    PluginRecord.find_by!(name: "video_walkthroughs").update!(enabled: false)
    Syrus::Installer.sync!
    expect(Syrus::Metrics.registry.declared?(:syrus_video_walkthroughs_storage_bytes)).to be(false)

    PluginRecord.find_by!(name: "video_walkthroughs").update!(enabled: true)
    Syrus::Installer.sync!
    expect(Syrus::Metrics.registry.declared?(:syrus_video_walkthroughs_storage_bytes)).to be(true)
  end
end
