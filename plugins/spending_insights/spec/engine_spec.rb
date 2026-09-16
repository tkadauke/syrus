require "rails_helper"

RSpec.describe SpendingInsights::Engine do
  it "is registered enabled by default for the standard bundled-plugin test setup" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "spending_insights" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(true)
    expect(manifest.enabled?).to be(true)
    expect(Syrus::PluginRegistry.providers_for(:sidebar_page)).to include(SpendingInsights::SidebarPages)
  end

  it "drops the sidebar page once the plugin is disabled" do
    PluginRecord.find_or_create_by!(name: "spending_insights") { |record| record.enabled = true }
    PluginRecord.find_by!(name: "spending_insights").update!(enabled: false)

    expect(Syrus::PluginRegistry.providers_for(:sidebar_page)).not_to include(SpendingInsights::SidebarPages)
  end

  # Plugin metrics follow while_enabled semantics: a disabled plugin emits no
  # series at all, which is what disambiguates "off" from "on and unused."
  # The declaration itself is a Syrus::Installer while_enabled effect, which
  # is sync-on-read (see MetricsController#sync_plugin_declarations) rather
  # than reapplied on a timer, so the test drives that same sync explicitly.
  it "declares its run cost metric only while enabled" do
    PluginRecord.find_or_create_by!(name: "spending_insights") { |record| record.enabled = true }
    Syrus::Installer.sync!
    expect(Syrus::Metrics.registry.declared?(:syrus_spending_insights_run_cost_usd_total)).to be(true)

    PluginRecord.find_by!(name: "spending_insights").update!(enabled: false)
    Syrus::Installer.sync!
    expect(Syrus::Metrics.registry.declared?(:syrus_spending_insights_run_cost_usd_total)).to be(false)

    PluginRecord.find_by!(name: "spending_insights").update!(enabled: true)
    Syrus::Installer.sync!
    expect(Syrus::Metrics.registry.declared?(:syrus_spending_insights_run_cost_usd_total)).to be(true)
  end

  # MetricsSampler registers via the manifest's `metrics do ... sampler
  # MetricsSampler end` DSL (Syrus::PluginApi::Definition#metrics), not a
  # plugin-owned tick_interval/on_tick -- it samples on the shared
  # control-plane tick (SampleGlobalMetricsJob) like every other sampler.
  it "registers its cost sampler only while enabled" do
    PluginRecord.find_or_create_by!(name: "spending_insights") { |record| record.enabled = true }
    Syrus::Installer.sync!
    expect(Syrus::Metrics.samplers).to include(SpendingInsights::MetricsSampler)

    PluginRecord.find_by!(name: "spending_insights").update!(enabled: false)
    Syrus::Installer.sync!
    expect(Syrus::Metrics.samplers).not_to include(SpendingInsights::MetricsSampler)

    PluginRecord.find_by!(name: "spending_insights").update!(enabled: true)
    Syrus::Installer.sync!
    expect(Syrus::Metrics.samplers).to include(SpendingInsights::MetricsSampler)
  end

  it "is treated as enabled on a fresh install with no prior PluginRecord row", :reset_plugin_registry do
    Syrus::PluginRegistry.reset!
    # The real engine already registered once at Rails boot, outside any
    # per-example transaction, so a row from that boot commit persists here.
    # Delete it to simulate the fresh-install state this test exercises.
    PluginRecord.where(name: "spending_insights").delete_all

    expect(PluginRecord.where(name: "spending_insights")).not_to exist

    SpendingInsights.register!

    expect(PluginRecord.find_by!(name: "spending_insights").enabled?).to be(true)
    expect(Syrus::PluginRegistry.providers_for(:sidebar_page)).to include(SpendingInsights::SidebarPages)

    Syrus::PluginRegistry.reset!
  end
end
