require "rails_helper"

RSpec.describe Coworkers::GrantCatalog do
  it "aggregates declarations from enabled chat tool set providers" do
    descriptor = described_class::Descriptor.new(
      name: "example.read", label: "Example", description: "Read examples", maximum_policy: "confirm",
      tools: [ "read_example" ], scope_options_callback: nil, scope_label_callback: nil, valid_scope_callback: nil
    )
    provider = Class.new do
      define_singleton_method(:coworker_grants) { [ descriptor ] }
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_mcp_tool_set).and_return([ provider ])

    expect(described_class.fetch("example.read")).to eq(descriptor)
    expect(described_class.policy_allowed?(descriptor, "auto")).to be(false)
    expect(described_class.policy_allowed?(descriptor, "confirm")).to be(true)
  end

  it "does not collect declarations absent from enabled providers" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_mcp_tool_set).and_return([])
    expect(described_class.names).not_to include("example.read")
  end

  it "explains why privileged grants are unavailable without verified confinement" do
    descriptor = described_class::Descriptor.new(
      name: "database.read", label: "Database", description: "Read a database", maximum_policy: "confirm",
      tools: [ "read_database" ], scope_options_callback: nil, scope_label_callback: nil, valid_scope_callback: nil,
      privileged: true
    )
    allow(Coworkers::PrivilegedGrantGate).to receive(:availability).with(descriptor).and_return(
      Coworkers::PrivilegedGrantGate::Availability.new(available?: false, reason: "confinement_unavailable")
    )

    expect(descriptor.as_json).to include(privileged: true, available: false, unavailable_reason: "confinement_unavailable")
  end

  it "covers every capability surfaced by the core coworker registry" do
    registry_names = McpToolRegistry.entries(surface: :coworker).map { |entry| entry.capability.to_s }.uniq
    expect(described_class.names).to include(*registry_names)
    expect(described_class.names).to include(*Admin::CapabilitySurfaceRegistry::COWORKER_MCP_CAPABILITIES)
  end
end
