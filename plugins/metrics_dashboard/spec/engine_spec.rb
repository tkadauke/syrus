require "rails_helper"

RSpec.describe MetricsDashboard::Engine do
  let(:manifest) do
    Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "metrics_dashboard" }
  end

  it "is registered and off by default" do
    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(false)
  end

  # Recording is driven by the plugin tick, and PluginTickSchedulerJob only
  # ticks enabled, healthy plugins. That is what makes disabling the plugin
  # genuinely stop recording rather than merely hide the page -- so the tick
  # interval and the callbacks provider are load-bearing, not decoration.
  it "records on the plugin tick, which only fires while enabled" do
    expect(manifest.tick_interval).to eq(1.minute)
    expect(Array(manifest.provides[:callbacks])).to include(MetricsDashboard::Callbacks)
  end

  describe "the sidebar page" do
    let(:page) { MetricsDashboard::SidebarPages.sidebar_pages.sole }

    # `paths` is the whole contract: React registers a route per entry and
    # PluginRouteResolver answers Rails' SPA wildcard from the same list. A page
    # whose paths omit one it handles renders the bare bootstrap shell on direct
    # navigation -- silently, because Rails still serves the shell.
    it "declares every path it handles" do
      expect(page[:paths]).to include(page[:path])
    end

    it "names a component the frontend loader can resolve" do
      expect(page[:component]).to eq("metrics_dashboard/MetricsDashboard")
      expect(Rails.root.join("plugins/metrics_dashboard/app/frontend/routes/MetricsDashboard.tsx")).to exist
    end
  end

  # The table carries the plugin's name, which is how Syrus::PluginPurge finds
  # and drops it. Without the prefix the plugin would be disableable but not
  # actually uninstallable.
  it "owns a table the purge machinery can find" do
    expect(MetricsDashboardSample.table_name).to start_with("metrics_dashboard")
  end
end
