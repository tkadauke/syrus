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
