require "rails_helper"

RSpec.describe Admin::PluginHostSurfaceAudit do
  it "accepts a public-only built-in inventory" do
    result = Admin::PluginHostSurfaceInventory::Result.new(
      constant: "Syrus::Host::Job", tier: "public", plugins: { "fixture_plugin" => 1 }, count: 1
    )
    inventory = instance_double(Admin::PluginHostSurfaceInventory, results: [ result ])

    expect(described_class.new(inventory:).findings).to eq([])
  end

  it "rejects a built-in plugin reference to an internal constant" do
    result = Admin::PluginHostSurfaceInventory::Result.new(
      constant: "InternalService", tier: "internal", plugins: { "fixture_plugin" => 1 }, count: 1
    )
    inventory = instance_double(Admin::PluginHostSurfaceInventory, results: [ result ])

    expect(described_class.new(inventory:).findings).to eq([
      "InternalService is referenced by fixture_plugin but is internal; add a facade under Syrus::Host with an API contract, or stop using it"
    ])
  end

  it "accepts an explicitly allowlisted internal reference" do
    result = Admin::PluginHostSurfaceInventory::Result.new(
      constant: "ExceptionalService", tier: "internal", plugins: { "fixture_plugin" => 1 }, count: 1
    )
    inventory = instance_double(Admin::PluginHostSurfaceInventory, results: [ result ])
    surface = instance_double(Syrus::PluginHostSurface, allowed_internal?: true)

    expect(described_class.new(inventory:, surface:).findings).to eq([])
  end
end
