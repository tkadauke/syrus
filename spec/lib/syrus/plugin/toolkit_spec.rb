# frozen_string_literal: true

require "rails_helper"

RSpec.describe Syrus::Plugin::Toolkit, :reset_plugin_registry do
  let(:discovery_context) { Syrus::Plugin::Context::ToolkitDiscoveryContext.new }

  before { described_class.restore_definition! }

  it "defines the toolkit family contracts and legacy mappings" do
    definition = Syrus::Plugin::Family.fetch(:toolkit)

    expect(definition.capabilities.keys).to eq(
      %i[workflow_tools chat_tools permissions run_context credential_probes secret_extractors]
    )
    expect(definition.legacy_mappings.keys).to eq(
      %i[mcp_tool_set chat_mcp_tool_set permission_provider mcp_run_context_contributor]
    )
  end

  it "adapts legacy-only registrations into family dispatch" do
    tool_set = Class.new do
      include Syrus::Plugin::McpToolSet
    end
    Syrus::PluginRegistry.register(
      name: "legacy_tools", version: "1", provides: { mcp_tool_set: tool_set }
    )

    expect(Syrus::Plugin::Dispatch.call(:toolkit, :workflow_tools, discovery_context)).to include(tool_set)
  end

  it "exposes family-only registrations through the legacy bridge" do
    stub_const("ToolkitFamilyOnlyToolSet", Class.new do
      def self.tool_definitions = []
    end)
    stub_const("ToolkitFamilyOnlyProvider", described_class.provider(
      key: "family", display_name: "Family", workflow_tools: "ToolkitFamilyOnlyToolSet"
    ))
    Syrus::PluginRegistry.register(
      name: "family_tools", version: "1", provides: {},
      family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
        family: :toolkit, provider: "ToolkitFamilyOnlyProvider", implements: %i[workflow_tools]
      ) ]
    )

    provider = Syrus::PluginRegistry.providers_for(:mcp_tool_set).find do |candidate|
      candidate.is_a?(Syrus::Plugin::LegacyBridge::Provider) && candidate.tool_definitions == []
    end
    expect(provider).not_to be_nil
    expect(provider.tool_definitions).to eq([])
  end

  it "reports doubled legacy and family registration" do
    stub_const("ToolkitDoubledToolSet", Class.new do
      include Syrus::Plugin::McpToolSet
    end)
    stub_const("ToolkitDoubledProvider", described_class.provider(
      key: "doubled", display_name: "Doubled", workflow_tools: "ToolkitDoubledToolSet"
    ))
    Syrus::PluginRegistry.register(
      name: "doubled", version: "1", provides: { mcp_tool_set: ToolkitDoubledToolSet },
      family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
        family: :toolkit, provider: "ToolkitDoubledProvider", implements: %i[workflow_tools]
      ) ]
    )

    expect(Syrus::PluginRegistry.legacy_bridge_duplicate_registrations.map(&:extension_point)).to include(:mcp_tool_set)
  end

  it "skips a failing tool provider and returns the remaining tool sets" do
    failing = Class.new do
      def self.key = "failing"
      def self.display_name = "Failing"
      def self.workflow_tools(_context) = raise("broken discovery")
    end
    healthy_tool_set = Class.new
    healthy = described_class.provider(
      key: "healthy", display_name: "Healthy", workflow_tools: healthy_tool_set.name
    )
    allow(healthy).to receive(:workflow_tools).and_return(healthy_tool_set)
    references = [ failing, healthy ].map.with_index do |provider, index|
      instance_double(Syrus::Plugin::CapabilityProvider,
        key: nil, provider_name: "provider-#{index}", invoke: nil).tap do |reference|
        allow(reference).to receive(:invoke).and_yield(provider)
      end
    end
    allow(Syrus::PluginRegistry).to receive(:capability_providers)
      .with(:toolkit, :workflow_tools).and_return(references)

    expect(Syrus::Plugin::Dispatch.call(:toolkit, :workflow_tools, discovery_context)).to eq([ healthy_tool_set ])
  end

  it "preserves non-empty run-context hashes through dispatch and runtime assembly" do
    attributes = { chat_session: Object.new, granted_capabilities: [ "code.read" ] }
    contributor = Class.new do
      define_singleton_method(:context_attributes) { |**| attributes }
    end
    stub_const("ToolkitRunContextContributor", contributor)
    stub_const("ToolkitRunContextProvider", described_class.provider(
      key: "run_context", display_name: "Run context", run_context: "ToolkitRunContextContributor"
    ))
    Syrus::PluginRegistry.register(
      name: "run_context", version: "1", provides: {},
      family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
        family: :toolkit, provider: "ToolkitRunContextProvider", provisional: %i[run_context]
      ) ]
    )

    expect(described_class.run_context_attributes(run: double, role: AgentRole::COWORKER)).to eq([ attributes ])
    expect(McpToolContext.send(:run_context_attributes, double, AgentRole::COWORKER)).to eq(attributes)
  end
end
