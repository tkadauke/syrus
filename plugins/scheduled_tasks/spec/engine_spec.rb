require "rails_helper"

RSpec.describe ScheduledTasks::Engine do
  it "is registered and enabled by default" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "scheduled_tasks" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(true)
    expect(manifest.tick_interval).to eq(1.minute)
    expect(Array(manifest.provides[:callbacks])).to include(ScheduledTasks::Callbacks)
  end

  # Plugin metrics follow while_enabled semantics: a disabled plugin emits no
  # series at all. The declaration is a Syrus::Installer while_enabled effect,
  # which is sync-on-read (see MetricsController#sync_plugin_declarations)
  # rather than reapplied on a timer, so the test drives that sync explicitly.
  it "declares its autopaused gauge only while enabled" do
    record = PluginRecord.find_or_initialize_by(name: "scheduled_tasks")
    record.update!(enabled: true)
    Syrus::Installer.sync!
    expect(Syrus::Metrics.registry.declared?(:syrus_scheduled_tasks_autopaused_total)).to be(true)

    record.update!(enabled: false)
    Syrus::Installer.sync!
    expect(Syrus::Metrics.registry.declared?(:syrus_scheduled_tasks_autopaused_total)).to be(false)

    record.update!(enabled: true)
    Syrus::Installer.sync!
    expect(Syrus::Metrics.registry.declared?(:syrus_scheduled_tasks_autopaused_total)).to be(true)
  end

  # The autopaused gauge is the declarative sample-block form (see
  # Syrus::PluginApi::Definition#metrics), not a hand-written sampler class --
  # it registers/unregisters into Syrus::Metrics's sampler registry alongside
  # the metric declaration, and samples on the shared control-plane tick
  # (SampleGlobalMetricsJob) rather than Callbacks#on_tick's own poll cadence.
  describe "the autopaused gauge sample block", :reset_plugin_registry do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }

    def task(state:)
      ScheduledTasks::Task.create!(
        user: user, repository: repository, name: "Task", prompt: "Do the thing.",
        kind: "cron", cron_expression: "0 9 * * 1", minute_offset: 5, pr_pileup_policy: "skip",
        state: state
      )
    end

    before do
      allow(Rails).to receive(:cache).and_return(cache)
      record = PluginRecord.find_or_initialize_by(name: "scheduled_tasks")
      record.update!(enabled: true)
      Syrus::Installer.sync!
    end

    it "registers its sampler only while enabled" do
      sampler = Syrus::Metrics.samplers.find { |s| s.respond_to?(:sampler_key) && s.sampler_key == "sampled_gauge:syrus_scheduled_tasks_autopaused_total" }
      expect(sampler).to be_present

      PluginRecord.find_by!(name: "scheduled_tasks").update!(enabled: false)
      Syrus::Installer.sync!
      expect(Syrus::Metrics.samplers).not_to include(sampler)
    end

    it "samples and refreshes the count of currently auto-paused tasks" do
      task(state: "auto_paused")
      task(state: "auto_paused")
      task(state: "scheduled")

      sampler = Syrus::Metrics.samplers.find { |s| s.respond_to?(:sampler_key) && s.sampler_key == "sampled_gauge:syrus_scheduled_tasks_autopaused_total" }
      sampler.sample!
      sampler.refresh_gauges!

      expect(Syrus::Metrics.render).to include("syrus_scheduled_tasks_autopaused_total 2")
    end
  end
end
