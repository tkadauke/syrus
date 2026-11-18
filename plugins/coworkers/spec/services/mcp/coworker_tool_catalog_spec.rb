require "rails_helper"

RSpec.describe Mcp::CoworkerToolCatalog do
  let(:provider) do
    Class.new do
      def self.coworker_grants
        [ { name: "example.records", tools: [ "read_example" ] } ]
      end

      def self.tool_definitions(tier:)
        return [] if tier == :deferred

        [ { name: "read_example", description: "Read examples", coworker_safe: true,
            capability: "example.records" } ]
      end
    end
  end
  let(:manifest) do
    Syrus::Plugin::Manifest.new(
      name: "example", version: "1", provides: { chat_mcp_tool_set: [ provider ] }, metadata: {}, enabled: enabled
    )
  end
  let(:enabled) { false }
  let(:health) { instance_double(Syrus::PluginHealth, healthy?: true) }

  before do
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([ manifest ])
    allow(Syrus::PluginRegistry).to receive(:health).and_return(health)
  end

  it "keeps installed disabled plugin capabilities in the catalog with an explicit state" do
    descriptor = described_class.all.find { |candidate| candidate.capability == "example.records" }

    expect(descriptor).to have_attributes(
      tool_name: "read_example", description: "Read examples", availability_state: :plugin_disabled
    )
  end

  it "still resolves explicitly ungated plugin tools" do
    allow(provider).to receive(:coworker_grants).and_return([])
    allow(provider).to receive(:tool_definitions).and_return(
      [ { name: "workspace_read", description: "Read workspace", coworker_safe: true, ungated: true } ]
    )

    expect(described_class.resolve("workspace_read")).to have_attributes(
      tool_name: "workspace_read", ungated: true, capability: nil, provider: provider
    )
  end

  it "derives a requestable capability for a shared plugin tool without a legacy grant" do
    allow(provider).to receive(:coworker_grants).and_return([])
    allow(provider).to receive(:tool_definitions).and_return(
      [ { name: "unclassified_tool", coworker_safe: true, capability: "missing.grant" } ]
    )

    descriptor = described_class.all.find { |candidate| candidate.tool_name == "unclassified_tool" }

    expect(descriptor).to have_attributes(capability: "missing.grant", ungated: false, availability_state: :plugin_disabled)
    expect(descriptor.grant).to include("default_policy" => "confirm", "tools" => [ "unclassified_tool" ])
  end

  context "when an enabled provider cannot supply a registered tool definition" do
    let(:enabled) { true }

    before { allow(provider).to receive(:tool_definitions).and_return([]) }

    it "retains the capability as unavailable instead of silently dropping it" do
      descriptor = described_class.all.find { |candidate| candidate.capability == "example.records" }

      expect(descriptor).to have_attributes(tool_name: "read_example", availability_state: :unavailable)
    end
  end
end
