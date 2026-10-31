require "rails_helper"

RSpec.describe Mcp::CoworkerToolCatalog do
  def provider(definition:, grants: [])
    Class.new do
      define_singleton_method(:tool_definitions) { |tier:| tier.nil? || tier == :essential ? [ definition ] : [] }
      define_singleton_method(:coworker_grants) { grants }
    end
  end

  it "resolves plugin tools through their declared coworker grant" do
    tool_set = provider(
      definition: { name: "plugin_read", coworker_safe: true, capability: "plugin.read" },
      grants: [ { name: "plugin.read", tools: [ "plugin_read" ] } ]
    )
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_mcp_tool_set).and_return([ tool_set ])

    expect(described_class.resolve("plugin_read")).to have_attributes(
      tool_name: "plugin_read", capability: "plugin.read", ungated: false, provider: tool_set
    )
  end

  it "allows explicitly ungated plugin tools without a grant" do
    tool_set = provider(definition: { name: "workspace_read", coworker_safe: true, ungated: true })
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_mcp_tool_set).and_return([ tool_set ])

    expect(described_class.resolve("workspace_read")).to have_attributes(ungated: true, capability: nil)
  end

  it "rejects every coworker tool with neither a resolvable grant nor an ungated declaration" do
    tool_set = provider(definition: { name: "unclassified_tool", coworker_safe: true, capability: "missing.grant" })
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_mcp_tool_set).and_return([ tool_set ])

    expect { described_class.all }
      .to raise_error(ArgumentError, 'coworker tool "unclassified_tool" has no resolvable grant and is not ungated')
  end
end
