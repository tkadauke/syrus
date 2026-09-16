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
end
