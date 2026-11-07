require "rails_helper"
require "tmpdir"

RSpec.describe Admin::PluginOwnershipAudit do
  def synthetic_ownership(quarantine: {})
    described_class::Ownership.new(
      plugin: "weather",
      path: "plugins/weather/config/plugin_ownership.yml",
      categories: { "vocabulary" => [ "forecast_widget" ] },
      vocabulary: [ "forecast_widget" ],
      quarantine:
    )
  end

  it "allows quarantined plugin vocabulary to shrink but rejects growth" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("app/services").mkpath
      source = root.join("app/services/dashboard.rb")
      source.write("forecast_widget = forecast_widget_provider\n")
      ownership = synthetic_ownership(quarantine: { "app/services/dashboard.rb" => 2 })

      audit = described_class.new(root:, ownerships: [ ownership ])
      expect(audit.violations).to eq([])

      source.write("forecast_widget = forecast_widget_provider(forecast_widget)\n")
      expect(audit.violations.map(&:message)).to contain_exactly(
        "app/services/dashboard.rb: weather owns 3 vocabulary occurrence(s), compatibility quarantine allows 2"
      )
    end
  end

  it "rejects owned vocabulary in a new core file" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("config").mkpath
      root.join("config/settings.yml").write("forecast_widget: true\n")

      audit = described_class.new(root:, ownerships: [ synthetic_ownership ])

      expect(audit.violations.map(&:path)).to eq([ "config/settings.yml" ])
    end
  end

  it "loads categorical ownership and the compatibility quarantine from a plugin manifest" do
    manifest = described_class.new.ownerships.find { |ownership| ownership.plugin == "coworkers" }

    expect(manifest.categories.keys).to contain_exactly(
      "configuration_keys", "documentation_paths", "frontend_contributions",
      "problem_codes", "route_prefixes", "step_kinds", "tables", "target_types",
      "tools", "vocabulary"
    )
    expect(manifest.quarantine).not_to be_empty
  end

  it "keeps the checked-in compatibility quarantine at or above the current inventory" do
    audit = described_class.new

    expect(audit.violations.map(&:message)).to eq([])
  end
end
