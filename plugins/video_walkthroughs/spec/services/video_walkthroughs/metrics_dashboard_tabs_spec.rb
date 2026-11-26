require "rails_helper"

RSpec.describe VideoWalkthroughs::MetricsDashboardTabs do
  it "declares one tab with a panel per metric it actually exports" do
    tab = described_class.metrics_dashboard_tabs.sole

    expect(tab[:id]).to eq("video_walkthroughs")
    expect(tab[:label]).to be_present
    expect(tab[:panels].map { |panel| panel[:key] }).to match_array(%w[storage_bytes])
  end

  # A panel pointed at a metric name this plugin doesn't actually declare
  # would render permanently empty -- the recorder can only capture what
  # /metrics exposes.
  it "only charts metrics its own `metrics do ... end` block declares" do
    PluginRecord.find_or_initialize_by(name: "video_walkthroughs").update!(enabled: true)
    Syrus::Installer.sync!

    described_class.metrics_dashboard_tabs.each do |tab|
      tab[:panels].each do |panel|
        expect(Syrus::Metrics.registry.declared?(panel[:metric].to_sym))
          .to be(true), "#{panel[:key]} points at #{panel[:metric]}, which is not a declared metric"
      end
    end
  end

  it "is registered under the metrics_dashboard:tab point" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "video_walkthroughs" }

    expect(manifest.provides["metrics_dashboard:tab"]).to eq(described_class)
  end

  it "is discoverable through the hosted point once both plugins are enabled" do
    PluginRecord.find_or_initialize_by(name: "video_walkthroughs").update!(enabled: true)
    PluginRecord.find_or_initialize_by(name: "metrics_dashboard").update!(enabled: true)

    expect(Syrus::PluginRegistry.providers_for("metrics_dashboard:tab")).to include(described_class)
  end
end
