require "rails_helper"

RSpec.describe Permissions::PluginContributions do
  let(:descriptor) { Permissions::Catalog.descriptors.first }
  let(:permission_provider) do
    Class.new do
      class << self
        attr_accessor :descriptor
        def permission_capability_descriptors = [ descriptor ]
      end
    end.tap { |provider| provider.descriptor = descriptor }
  end
  let(:tool_provider) { Class.new }

  def manifest(name:, enabled:, provides:)
    Syrus::Plugin::Manifest.new(
      name:, display_name: name.titleize, version: "1", provides:, metadata: {}, enabled:
    )
  end

  it "separates enabled and available registry plugins and reports their generic contributions" do
    installed = manifest(name: "active_example", enabled: true,
      provides: { permission_provider: permission_provider, chat_mcp_tool_set: tool_provider })
    available = manifest(name: "available_example", enabled: false,
      provides: { mcp_tool_set: tool_provider })
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([ installed, available ])
    allow(Syrus::PluginRegistry).to receive(:all_tool_definitions).with(tool_provider).and_return(
      [ { name: "read_example", capability_descriptor: descriptor } ]
    )

    payload = described_class.as_json.index_by { |plugin| plugin[:name] }

    expect(payload.fetch("active_example")).to include(
      installed: true,
      tools: [ "read_example" ],
      capabilities: [ include(identifier: descriptor.capability, name: descriptor.presentation.capability_name) ]
    )
    expect(payload.fetch("available_example")).to include(installed: false, tools: [ "read_example" ])
  end

  it "omits registry plugins that contribute neither permissions nor tools" do
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return(
      [ manifest(name: "presentation_only", enabled: true, provides: { sidebar_page: Class.new }) ]
    )

    expect(described_class.as_json).to be_empty
  end
end
