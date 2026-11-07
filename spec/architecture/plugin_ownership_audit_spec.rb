require "rails_helper"
require "tmpdir"

RSpec.describe Admin::PluginOwnershipAudit do
  OWNERSHIP_CATEGORIES = %w[
    configuration_keys documentation_paths frontend_contributions problem_codes
    route_prefixes step_kinds tables target_types tools vocabulary
  ].freeze

  def synthetic_ownership(quarantine: {})
    described_class::Ownership.new(
      plugin: "weather",
      path: "plugins/weather/config/plugin_ownership.yml",
      categories: { "vocabulary" => [ "forecast_widget" ] },
      vocabulary: [ "forecast_widget" ],
      quarantine:
    )
  end

  def write_synthetic_manifest(root)
    manifest = root.join("plugins/weather/config/plugin_ownership.yml")
    manifest.dirname.mkpath
    manifest.write(<<~YAML)
      plugin: weather
      ownership:
        configuration_keys: [weather_api_key]
        documentation_paths: [plugins/weather/docs]
        frontend_contributions: [weather/Forecast]
        problem_codes: [weather_unavailable]
        route_prefixes: [/api/v1/app/weather]
        step_kinds: [weather_forecast]
        tables: [weather_forecasts]
        target_types: [weather_station]
        tools: [read_forecast]
        vocabulary: [forecast_widget]
      compatibility_quarantine:
        app/services/dashboard.rb: 2
    YAML
  end

  it "reports baseline differences for both shrinkage and growth" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("app/services").mkpath
      source = root.join("app/services/dashboard.rb")
      source.write("forecast_widget = forecast_widget_provider\n")
      ownership = synthetic_ownership(quarantine: { "app/services/dashboard.rb" => 2 })

      audit = described_class.new(root:, ownerships: [ ownership ])
      expect(audit.findings).to eq([])

      source.write("forecast_widget = true\n")
      expect(audit.findings.map(&:message)).to contain_exactly(
        "app/services/dashboard.rb: weather vocabulary inventory actual 1, baseline 2, trend -1"
      )

      source.write("forecast_widget = forecast_widget_provider(forecast_widget)\n")
      expect(audit.findings.map(&:message)).to contain_exactly(
        "app/services/dashboard.rb: weather vocabulary inventory actual 3, baseline 2, trend +1"
      )
    end
  end

  it "reports owned vocabulary in a new core file" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("config").mkpath
      root.join("config/settings.yml").write("forecast_widget: true\n")

      audit = described_class.new(root:, ownerships: [ synthetic_ownership ])

      expect(audit.findings.map(&:path)).to eq([ "config/settings.yml" ])
    end
  end

  it "does not follow core-file symlinks outside the audit root" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory).join("repository")
      root.join("app/services").mkpath
      outside = Pathname.new(directory).join("outside.rb")
      outside.write("forecast_widget = true\n")
      root.join("app/services/outside.rb").make_symlink(outside)

      audit = described_class.new(root:, ownerships: [ synthetic_ownership ])

      expect(audit.findings).to eq([])
    end
  end

  it "loads categorical ownership and the compatibility quarantine from a plugin manifest" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      write_synthetic_manifest(root)
      manifest = described_class.new(root:).ownerships.fetch(0)

      expect(manifest.plugin).to eq("weather")
      expect(manifest.categories.keys).to contain_exactly(*OWNERSHIP_CATEGORIES)
      expect(manifest.quarantine).to eq("app/services/dashboard.rb" => 2)
    end
  end
end
