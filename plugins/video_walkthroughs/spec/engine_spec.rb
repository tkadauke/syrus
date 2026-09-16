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

  # The storage_bytes gauge is the declarative sample-block form (see
  # Syrus::PluginApi::Definition#metrics), not a hand-written sampler class --
  # it registers/unregisters into Syrus::Metrics's sampler registry alongside
  # the metric declaration, and samples on the shared control-plane tick
  # (SampleGlobalMetricsJob) rather than Callbacks#on_tick's own daily
  # retention cadence.
  describe "the storage_bytes gauge sample block", :reset_plugin_registry do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    before do
      allow(Rails).to receive(:cache).and_return(cache)
      record = PluginRecord.find_or_initialize_by(name: "video_walkthroughs")
      record.update!(enabled: true)
      Syrus::Installer.sync!
    end

    def find_sampler
      Syrus::Metrics.samplers.find { |s| s.respond_to?(:sampler_key) && s.sampler_key == "sampled_gauge:syrus_video_walkthroughs_storage_bytes" }
    end

    it "registers its sampler only while enabled" do
      sampler = find_sampler
      expect(sampler).to be_present

      PluginRecord.find_by!(name: "video_walkthroughs").update!(enabled: false)
      Syrus::Installer.sync!
      expect(Syrus::Metrics.samplers).not_to include(sampler)
    end

    it "samples and refreshes the total stored bytes" do
      allow(VideoWalkthroughs::Walkthrough).to receive(:total_stored_bytes).and_return(1_500_000_000)

      sampler = find_sampler
      sampler.sample!
      sampler.refresh_gauges!

      expect(Syrus::Metrics.render).to include("syrus_video_walkthroughs_storage_bytes 1500000000")
    end
  end
end
