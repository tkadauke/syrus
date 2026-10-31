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

  it "covers every capability surfaced by the core coworker registry" do
    registry_names = McpToolRegistry.entries(surface: :coworker).map { |entry| entry.capability.to_s }.uniq
    expect(described_class.names).to include(*registry_names)
    expect(Admin::CapabilitySurfaceRegistry::COWORKER_MCP_CAPABILITIES).to match_array(registry_names)
  end
end
