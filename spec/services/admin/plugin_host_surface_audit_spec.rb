require "rails_helper"

RSpec.describe Admin::PluginHostSurfaceAudit do
  def entry(name, tier = "legacy")
    Syrus::PluginHostSurface::Entry.new(name:, tier:, since: nil, notes: nil)
  end

  it "gives an actionable failure for an unlisted plugin reference" do
    result = Admin::PluginHostSurfaceInventory::Result.new(
      constant: "InternalService", tier: "unlisted", plugins: { "fixture_plugin" => 1 }, count: 1
    )
    inventory = instance_double(Admin::PluginHostSurfaceInventory, results: [ result ])
    surface = instance_double(Syrus::PluginHostSurface, legacy_entries: [], legacy_baseline: 0)

    expect(described_class.new(inventory:, surface:).findings).to contain_exactly(
      "InternalService is referenced by fixture_plugin but is not in the plugin host surface; list it as public with a documented contract, or stop using it"
    )
  end

  it "asks to remove a legacy entry after its last reference disappears" do
    surface = instance_double(Syrus::PluginHostSurface, legacy_entries: [ entry("UnusedService") ], legacy_baseline: 1)
    inventory = instance_double(Admin::PluginHostSurfaceInventory, results: [])

    expect(described_class.new(inventory:, surface:).findings).to contain_exactly(
      "UnusedService is legacy but no built-in plugin references it; remove it from config/plugin_host_surface.yml"
    )
  end

  it "rejects growth beyond the committed legacy baseline" do
    surface = instance_double(
      Syrus::PluginHostSurface,
      legacy_entries: [ entry("One"), entry("Two") ],
      legacy_baseline: 1
    )
    results = %w[One Two].map do |name|
      Admin::PluginHostSurfaceInventory::Result.new(constant: name, tier: "legacy", plugins: { "fixture_plugin" => 1 }, count: 1)
    end
    inventory = instance_double(Admin::PluginHostSurfaceInventory, results:)

    expect(described_class.new(inventory:, surface:).findings).to include(
      "legacy plugin host surface grew from 1 to 2; list new APIs as public with a documented contract, or stop using them"
    )
  end

  it "requires the baseline to follow a shrinking legacy set" do
    surface = instance_double(Syrus::PluginHostSurface, legacy_entries: [ entry("One") ], legacy_baseline: 2)
    result = Admin::PluginHostSurfaceInventory::Result.new(
      constant: "One", tier: "legacy", plugins: { "fixture_plugin" => 1 }, count: 1
    )
    inventory = instance_double(Admin::PluginHostSurfaceInventory, results: [ result ])

    expect(described_class.new(inventory:, surface:).findings).to include(
      "legacy plugin host surface shrank from 2 to 1; lower legacy_baseline to 1 so it cannot grow back"
    )
  end
end
