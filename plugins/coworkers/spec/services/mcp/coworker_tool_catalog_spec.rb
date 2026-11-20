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

      def self.coworker_discovery_state(_chat_session) = :available
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

  it "loads each provider tier once instead of rediscovering tiers for every tool" do
    allow(provider).to receive(:coworker_grants).and_return([])
    allow(provider).to receive(:tool_definitions) do |tier:|
      case tier
      when :essential
        [ { name: "read_example", coworker_safe: true, capability: "example.records" } ]
      when :deferred
        [ { name: "archive_example", coworker_safe: true, capability: "example.records" } ]
      else
        [
          { name: "read_example", coworker_safe: true, capability: "example.records" },
          { name: "archive_example", coworker_safe: true, capability: "example.records" }
        ]
      end
    end

    descriptors = described_class.all.select { |candidate| candidate.provider == provider }

    expect(descriptors.map { |descriptor| [ descriptor.tool_name, descriptor.tier ] }).to contain_exactly(
      [ "read_example", :essential ], [ "archive_example", :deferred ]
    )
    expect(provider).to have_received(:tool_definitions).exactly(3).times
  end

  it "resolves provider availability once per catalog build and again for the next build" do
    enabled_manifest = Syrus::Plugin::Manifest.new(
      name: "example", version: "1", provides: { chat_mcp_tool_set: [ provider ] }, metadata: {}, enabled: true
    )
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([ enabled_manifest ])
    allow(provider).to receive(:coworker_discovery_state).and_return(:resource_unconfigured, :available)
    allow(provider).to receive(:tool_definitions).and_return(
      [
        { name: "read_example", coworker_safe: true, capability: "example.records" },
        { name: "list_examples", coworker_safe: true, capability: "example.records" }
      ]
    )

    first = described_class.all.select { |candidate| candidate.provider == provider }
    second = described_class.all.select { |candidate| candidate.provider == provider }

    expect(first.map(&:availability_state).uniq).to eq([ :resource_unconfigured ])
    expect(second.map(&:availability_state).uniq).to eq([ :available ])
    expect(provider).to have_received(:coworker_discovery_state).twice
  end

  it "observes plugin lifecycle changes on the next catalog build" do
    disabled_manifest = manifest
    enabled_manifest = Syrus::Plugin::Manifest.new(
      name: "example", version: "1", provides: { chat_mcp_tool_set: [ provider ] }, metadata: {}, enabled: true
    )
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return(
      [ disabled_manifest ], [ enabled_manifest ], [ enabled_manifest ], [], [ enabled_manifest ]
    )
    allow(health).to receive(:healthy?).and_return(true, false, true)

    states = 5.times.map do
      described_class.all.find { |candidate| candidate.provider == provider }&.availability_state
    end

    expect(states).to eq([ :plugin_disabled, :available, :unavailable, nil, :available ])
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
