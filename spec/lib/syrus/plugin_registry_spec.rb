require "rails_helper"

RSpec.describe Syrus::PluginRegistry do
  around do |ex|
    described_class.reset!
    ex.run
    described_class.reset!
  end

  let(:agent_provider_class) do
    Class.new { include Syrus::Plugin::AgentProvider }
  end

  let(:mcp_tool_set_class) do
    Class.new { include Syrus::Plugin::McpToolSet }
  end

  let(:input_source_class) do
    Class.new { include Syrus::Plugin::InputSource }
  end

  describe ".register" do
    it "stores the plugin manifest" do
      described_class.register(name: "test_plugin", version: "1.0.0")
      manifests = described_class.all_plugins
      expect(manifests.size).to eq(1)
      expect(manifests.first.name).to eq("test_plugin")
      expect(manifests.first.version).to eq("1.0.0")
    end

    it "stores extra metadata on the manifest" do
      described_class.register(name: "test_plugin", version: "1.0.0", author: "Alice")
      expect(described_class.all_plugins.first.metadata[:author]).to eq("Alice")
    end

    it "accepts an empty provides hash" do
      expect {
        described_class.register(name: "empty_plugin", version: "0.1.0", provides: {})
      }.not_to raise_error
    end

    it "accepts valid extension points with correct interface modules" do
      expect {
        described_class.register(
          name: "full_plugin", version: "1.0.0",
          provides: {
            agent_provider: agent_provider_class,
            mcp_tool_set:   mcp_tool_set_class,
            input_source:   input_source_class
          }
        )
      }.not_to raise_error
    end

    it "raises RegistrationError for unknown extension point keys" do
      expect {
        described_class.register(
          name: "bad_plugin", version: "1.0.0",
          provides: { unknown_point: agent_provider_class }
        )
      }.to raise_error(described_class::RegistrationError, /Unknown extension point/)
    end

    it "raises RegistrationError when class does not include the required interface module" do
      plain_class = Class.new

      expect {
        described_class.register(
          name: "bad_plugin", version: "1.0.0",
          provides: { agent_provider: plain_class }
        )
      }.to raise_error(described_class::RegistrationError, /must include Syrus::Plugin::AgentProvider/)
    end

    it "raises RegistrationError when mcp_tool_set class lacks the interface module" do
      plain_class = Class.new

      expect {
        described_class.register(
          name: "bad_plugin", version: "1.0.0",
          provides: { mcp_tool_set: plain_class }
        )
      }.to raise_error(described_class::RegistrationError, /must include Syrus::Plugin::McpToolSet/)
    end

    it "raises RegistrationError when input_source class lacks the interface module" do
      plain_class = Class.new

      expect {
        described_class.register(
          name: "bad_plugin", version: "1.0.0",
          provides: { input_source: plain_class }
        )
      }.to raise_error(described_class::RegistrationError, /must include Syrus::Plugin::InputSource/)
    end

    it "allows the same extension point to be provided by multiple plugins" do
      second_provider = Class.new { include Syrus::Plugin::AgentProvider }

      described_class.register(name: "plugin_a", version: "1.0.0", provides: { agent_provider: agent_provider_class })
      described_class.register(name: "plugin_b", version: "1.0.0", provides: { agent_provider: second_provider })

      expect(described_class.providers_for(:agent_provider)).to contain_exactly(agent_provider_class, second_provider)
    end
  end

  describe ".providers_for" do
    it "returns only classes registered for the requested extension point" do
      described_class.register(
        name: "multi_plugin", version: "1.0.0",
        provides: { agent_provider: agent_provider_class, mcp_tool_set: mcp_tool_set_class }
      )

      expect(described_class.providers_for(:agent_provider)).to eq([agent_provider_class])
      expect(described_class.providers_for(:mcp_tool_set)).to eq([mcp_tool_set_class])
    end

    it "returns an empty array when no plugin provides the requested extension point" do
      described_class.register(name: "plugin", version: "1.0.0", provides: { mcp_tool_set: mcp_tool_set_class })

      expect(described_class.providers_for(:agent_provider)).to eq([])
    end

    it "returns an empty array when no plugins are registered" do
      expect(described_class.providers_for(:agent_provider)).to eq([])
    end
  end

  describe ".all_plugins" do
    it "returns a snapshot that is not affected by subsequent registrations" do
      described_class.register(name: "plugin_a", version: "1.0.0")
      snapshot = described_class.all_plugins
      described_class.register(name: "plugin_b", version: "2.0.0")

      expect(snapshot.size).to eq(1)
      expect(described_class.all_plugins.size).to eq(2)
    end
  end

  describe ".reset!" do
    it "clears all registered plugins" do
      described_class.register(name: "plugin", version: "1.0.0")
      expect(described_class.all_plugins).not_to be_empty

      described_class.reset!

      expect(described_class.all_plugins).to be_empty
    end

    it "clears providers so providers_for returns an empty array" do
      described_class.register(name: "plugin", version: "1.0.0", provides: { agent_provider: agent_provider_class })
      described_class.reset!

      expect(described_class.providers_for(:agent_provider)).to eq([])
    end
  end

  describe "Manifest" do
    it "is a Data object with name, version, provides, and metadata" do
      described_class.register(name: "manifest_plugin", version: "3.0.0", custom_key: "value")
      manifest = described_class.all_plugins.first

      expect(manifest).to be_a(Syrus::Plugin::Manifest)
      expect(manifest.name).to eq("manifest_plugin")
      expect(manifest.version).to eq("3.0.0")
      expect(manifest.provides).to eq({})
      expect(manifest.metadata).to eq({ custom_key: "value" })
    end
  end
end
