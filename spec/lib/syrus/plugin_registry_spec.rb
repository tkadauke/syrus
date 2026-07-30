require "rails_helper"

RSpec.describe Syrus::PluginRegistry, :reset_plugin_registry do
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

  let(:test_result_parser_class) do
    Class.new { include Syrus::Plugin::TestResultParser }
  end

  let(:coverage_analyzer_class) do
    Class.new { include Syrus::Plugin::CoverageAnalyzer }
  end

  describe "EXTENSION_POINTS" do
    it "includes :coverage_analyzer" do
      expect(described_class::EXTENSION_POINTS).to include(:coverage_analyzer)
    end
  end

  describe "INTERFACE_FOR" do
    it "maps :coverage_analyzer to Syrus::Plugin::CoverageAnalyzer" do
      expect(described_class::INTERFACE_FOR[:coverage_analyzer].call).to eq(Syrus::Plugin::CoverageAnalyzer)
    end
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

    it "stores description, homepage, and icon_url on the manifest" do
      described_class.register(
        name:        "rich_plugin",
        version:     "2.0.0",
        description: "A richly annotated plugin.",
        homepage:    "https://example.com/rich_plugin",
        icon_url:    "https://example.com/icon.png"
      )
      manifest = described_class.all_plugins.first
      expect(manifest.description).to eq("A richly annotated plugin.")
      expect(manifest.homepage).to eq("https://example.com/rich_plugin")
      expect(manifest.icon_url).to eq("https://example.com/icon.png")
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
            agent_provider:     agent_provider_class,
            mcp_tool_set:       mcp_tool_set_class,
            input_source:       input_source_class,
            test_result_parser: test_result_parser_class,
            coverage_analyzer:  coverage_analyzer_class
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

    it "raises RegistrationError when test_result_parser class lacks the interface module" do
      plain_class = Class.new

      expect {
        described_class.register(
          name: "bad_plugin", version: "1.0.0",
          provides: { test_result_parser: plain_class }
        )
      }.to raise_error(described_class::RegistrationError, /must include Syrus::Plugin::TestResultParser/)
    end

    it "raises RegistrationError when coverage_analyzer class lacks the interface module" do
      plain_class = Class.new

      expect {
        described_class.register(
          name: "bad_plugin", version: "1.0.0",
          provides: { coverage_analyzer: plain_class }
        )
      }.to raise_error(described_class::RegistrationError, /must include Syrus::Plugin::CoverageAnalyzer/)
    end

    it "allows the same extension point to be provided by multiple plugins" do
      second_provider = Class.new { include Syrus::Plugin::AgentProvider }

      described_class.register(name: "plugin_a", version: "1.0.0", provides: { agent_provider: agent_provider_class })
      described_class.register(name: "plugin_b", version: "1.0.0", provides: { agent_provider: second_provider })

      expect(described_class.providers_for(:agent_provider)).to contain_exactly(agent_provider_class, second_provider)
    end

    context "MCP tool name collision detection" do
      def make_tool_set(*tool_names)
        names = tool_names
        Class.new do
          include Syrus::Plugin::McpToolSet
          define_method(:tool_definitions) { names.map { |n| { name: n } } }
          define_singleton_method(:tool_definitions) { names.map { |n| { name: n } } }
          def self.available_for?(_repo) = true
          def handle(tool_name, params, context) = nil
        end
      end

      it "raises RegistrationError when a second tool set registers a name already claimed by a first" do
        set_a = make_tool_set("tool_one", "tool_two")
        set_b = make_tool_set("tool_three", "tool_one")

        described_class.register(name: "plugin_a", version: "1.0.0", provides: { mcp_tool_set: set_a })

        expect {
          described_class.register(name: "plugin_b", version: "1.0.0", provides: { mcp_tool_set: set_b })
        }.to raise_error(described_class::RegistrationError, /MCP tool name collision.*tool_one/)
      end

      it "does not raise when two tool sets share no tool names" do
        set_a = make_tool_set("tool_alpha")
        set_b = make_tool_set("tool_beta")

        described_class.register(name: "plugin_a", version: "1.0.0", provides: { mcp_tool_set: set_a })

        expect {
          described_class.register(name: "plugin_b", version: "1.0.0", provides: { mcp_tool_set: set_b })
        }.not_to raise_error
      end

      it "does not add the second plugin when its registration raises a collision" do
        set_a = make_tool_set("colliding_tool")
        set_b = make_tool_set("colliding_tool")

        described_class.register(name: "plugin_a", version: "1.0.0", provides: { mcp_tool_set: set_a })

        begin
          described_class.register(name: "plugin_b", version: "1.0.0", provides: { mcp_tool_set: set_b })
        rescue described_class::RegistrationError
          nil
        end

        expect(described_class.all_plugins.map(&:name)).to eq([ "plugin_a" ])
      end
    end

    it "creates a PluginRecord with enabled: true when none exists" do
      expect {
        described_class.register(name: "new_plugin", version: "1.0.0")
      }.to change { PluginRecord.where(name: "new_plugin", enabled: true).count }.by(1)
    end

    it "does not flip enabled on an existing PluginRecord" do
      PluginRecord.create!(name: "existing_plugin", enabled: false)
      described_class.register(name: "existing_plugin", version: "1.0.0")
      expect(PluginRecord.find_by!(name: "existing_plugin").enabled).to be(false)
    end

    it "is resilient when the plugin_records table does not exist" do
      allow(PluginRecord).to receive(:find_or_create_by!).and_raise(ActiveRecord::StatementInvalid)
      expect {
        described_class.register(name: "resilient_plugin", version: "1.0.0")
      }.not_to raise_error
      expect(described_class.all_plugins.map(&:name)).to include("resilient_plugin")
    end

    it "is resilient when the database is unavailable during boot" do
      allow(PluginRecord).to receive(:find_or_create_by!).and_raise(ActiveRecord::ConnectionNotEstablished)
      expect {
        described_class.register(name: "boot_plugin", version: "1.0.0")
      }.not_to raise_error
      expect(described_class.all_plugins.map(&:name)).to include("boot_plugin")
    end
  end

  describe ".providers_for" do
    it "returns only classes registered for the requested extension point" do
      described_class.register(
        name: "multi_plugin", version: "1.0.0",
        provides: { agent_provider: agent_provider_class, mcp_tool_set: mcp_tool_set_class }
      )

      expect(described_class.providers_for(:agent_provider)).to eq([ agent_provider_class ])
      expect(described_class.providers_for(:mcp_tool_set)).to eq([ mcp_tool_set_class ])
    end

    it "returns test result parser providers" do
      described_class.register(
        name: "test_parser_plugin", version: "1.0.0",
        provides: { test_result_parser: test_result_parser_class }
      )

      expect(described_class.providers_for(:test_result_parser)).to eq([ test_result_parser_class ])
    end

    it "returns coverage analyzer providers" do
      described_class.register(
        name: "coverage_plugin", version: "1.0.0",
        provides: { coverage_analyzer: coverage_analyzer_class }
      )

      expect(described_class.providers_for(:coverage_analyzer)).to eq([ coverage_analyzer_class ])
    end

    it "returns an empty array when no plugin provides the requested extension point" do
      described_class.register(name: "plugin", version: "1.0.0", provides: { mcp_tool_set: mcp_tool_set_class })

      expect(described_class.providers_for(:agent_provider)).to eq([])
    end

    it "returns an empty array when no plugins are registered" do
      expect(described_class.providers_for(:agent_provider)).to eq([])
    end

    it "excludes providers from plugins where PluginRecord.enabled is false" do
      described_class.register(name: "disabled_plugin", version: "1.0.0", provides: { agent_provider: agent_provider_class })
      PluginRecord.find_by!(name: "disabled_plugin").update!(enabled: false)

      expect(described_class.providers_for(:agent_provider)).to eq([])
    end

    it "includes providers from enabled plugins and excludes disabled ones" do
      enabled_provider  = Class.new { include Syrus::Plugin::AgentProvider }
      disabled_provider = Class.new { include Syrus::Plugin::AgentProvider }

      described_class.register(name: "enabled_plugin",  version: "1.0.0", provides: { agent_provider: enabled_provider })
      described_class.register(name: "disabled_plugin", version: "1.0.0", provides: { agent_provider: disabled_provider })
      PluginRecord.find_by!(name: "disabled_plugin").update!(enabled: false)

      expect(described_class.providers_for(:agent_provider)).to eq([ enabled_provider ])
    end

    it "returns all plugins when the plugin_records table does not exist" do
      described_class.register(name: "plugin_a", version: "1.0.0", provides: { agent_provider: agent_provider_class })
      allow(PluginRecord).to receive(:where).and_raise(ActiveRecord::StatementInvalid)

      expect(described_class.providers_for(:agent_provider)).to eq([ agent_provider_class ])
    end

    it "returns all plugins when the database is unavailable" do
      described_class.register(name: "plugin_a", version: "1.0.0", provides: { agent_provider: agent_provider_class })
      allow(PluginRecord).to receive(:where).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect(described_class.providers_for(:agent_provider)).to eq([ agent_provider_class ])
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

    it "reflects current enabled state from DB" do
      described_class.register(name: "toggled_plugin", version: "1.0.0")
      PluginRecord.find_by!(name: "toggled_plugin").update!(enabled: false)

      manifest = described_class.all_plugins.find { |m| m.name == "toggled_plugin" }
      expect(manifest.enabled).to be(false)
      expect(manifest.enabled?).to be(false)
    end

    it "reports enabled: true for plugins without a PluginRecord (table missing guard)" do
      described_class.register(name: "unrecorded", version: "1.0.0")
      allow(PluginRecord).to receive(:all).and_raise(ActiveRecord::StatementInvalid)

      manifest = described_class.all_plugins.find { |m| m.name == "unrecorded" }
      expect(manifest.enabled?).to be(true)
    end
  end

  describe ".registered_names" do
    it "returns registered plugin names without consulting PluginRecord state" do
      described_class.register(name: "plugin_a", version: "1.0.0")
      allow(PluginRecord).to receive(:all).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect(described_class.registered_names).to eq([ "plugin_a" ])
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

    it "clears coverage analyzer providers so providers_for returns an empty array" do
      described_class.register(name: "plugin", version: "1.0.0", provides: { coverage_analyzer: coverage_analyzer_class })
      described_class.reset!

      expect(described_class.providers_for(:coverage_analyzer)).to eq([])
    end
  end

  describe "Manifest" do
    it "is a Data object with name, version, provides, metadata, description, homepage, icon_url, and enabled" do
      described_class.register(
        name:        "manifest_plugin",
        version:     "3.0.0",
        custom_key:  "value",
        description: "Desc",
        homepage:    "https://example.com"
      )
      manifest = described_class.all_plugins.first

      expect(manifest).to be_a(Syrus::Plugin::Manifest)
      expect(manifest.name).to eq("manifest_plugin")
      expect(manifest.version).to eq("3.0.0")
      expect(manifest.provides).to eq({})
      expect(manifest.metadata).to eq({ custom_key: "value" })
      expect(manifest.description).to eq("Desc")
      expect(manifest.homepage).to eq("https://example.com")
      expect(manifest.icon_url).to be_nil
      expect(manifest.enabled).to be(true)
    end

    it "exposes enabled? as a boolean predicate" do
      described_class.register(name: "pred_plugin", version: "1.0.0")
      manifest = described_class.all_plugins.first
      expect(manifest.enabled?).to be(true)
    end
  end
end
