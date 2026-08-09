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

  let(:chat_provider_class) do
    Class.new { include Syrus::Plugin::ChatProvider }
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

  let(:preview_provider_class) do
    Class.new { include Syrus::Plugin::PreviewProvider }
  end

  let(:admin_page_class) do
    Class.new { include Syrus::Plugin::AdminPage }
  end

  let(:chat_mcp_tool_set_class) do
    Class.new { include Syrus::Plugin::ChatMcpToolSet }
  end

  let(:source_control_provider_class) do
    Class.new { include Syrus::Plugin::SourceControlProvider }
  end

  let(:artifact_renderer_class) do
    Class.new { include Syrus::Plugin::ArtifactRenderer }
  end

  describe "EXTENSION_POINTS" do
    it "includes :chat_provider and :coverage_analyzer" do
      expect(described_class::EXTENSION_POINTS).to include(:chat_provider, :coverage_analyzer)
    end

    it "includes :preview_provider" do
      expect(described_class::EXTENSION_POINTS).to include(:preview_provider)
    end

    it "includes :admin_page and :chat_mcp_tool_set" do
      expect(described_class::EXTENSION_POINTS).to include(:admin_page, :chat_mcp_tool_set)
    end

    it "includes :source_control_provider" do
      expect(described_class::EXTENSION_POINTS).to include(:source_control_provider)
    end

    it "includes :prompt_injector" do
      expect(described_class::EXTENSION_POINTS).to include(:prompt_injector)
    end

    it "includes :artifact_renderer" do
      expect(described_class::EXTENSION_POINTS).to include(:artifact_renderer)
    end

    it "includes :callbacks" do
      expect(described_class::EXTENSION_POINTS).to include(:callbacks)
    end

    it "is frozen" do
      expect(described_class::EXTENSION_POINTS).to be_frozen
    end
  end

  describe "INTERFACE_FOR" do
    it "maps :coverage_analyzer to Syrus::Plugin::CoverageAnalyzer" do
      expect(described_class::INTERFACE_FOR[:coverage_analyzer].call).to eq(Syrus::Plugin::CoverageAnalyzer)
    end

    it "maps :chat_provider to Syrus::Plugin::ChatProvider" do
      expect(described_class::INTERFACE_FOR[:chat_provider].call).to eq(Syrus::Plugin::ChatProvider)
    end

    it "maps :preview_provider to Syrus::Plugin::PreviewProvider" do
      expect(described_class::INTERFACE_FOR[:preview_provider].call).to eq(Syrus::Plugin::PreviewProvider)
    end

    it "maps UI and chat MCP extension points to their interfaces" do
      expect(described_class::INTERFACE_FOR[:admin_page].call).to eq(Syrus::Plugin::AdminPage)
      expect(described_class::INTERFACE_FOR[:chat_mcp_tool_set].call).to eq(Syrus::Plugin::ChatMcpToolSet)
    end

    it "maps :source_control_provider to Syrus::Plugin::SourceControlProvider" do
      expect(described_class::INTERFACE_FOR[:source_control_provider].call).to eq(Syrus::Plugin::SourceControlProvider)
    end

    it "maps :prompt_injector to Syrus::Plugin::PromptInjector" do
      expect(described_class::INTERFACE_FOR[:prompt_injector].call).to eq(Syrus::Plugin::PromptInjector)
    end

    it "maps :artifact_renderer to Syrus::Plugin::ArtifactRenderer" do
      expect(described_class::INTERFACE_FOR[:artifact_renderer].call).to eq(Syrus::Plugin::ArtifactRenderer)
    end

    it "maps :callbacks to Syrus::Plugin::Callbacks" do
      expect(described_class::INTERFACE_FOR[:callbacks].call).to eq(Syrus::Plugin::Callbacks)
    end

    it "gives artifact renderer providers the class contract used by the registry" do
      provider = Class.new { include Syrus::Plugin::ArtifactRenderer }

      expect(provider).to respond_to(:artifact_type)
      expect(provider).to respond_to(:renderer_type)
      expect(provider).to respond_to(:payload_schema)
      expect { provider.artifact_type }.to raise_error(NotImplementedError, /must implement \.artifact_type/)
      expect { provider.renderer_type }.to raise_error(NotImplementedError, /must implement \.renderer_type/)
      expect(provider.payload_schema).to be_nil
    end

    it "gives coverage analyzer providers the class call contract used by the registry" do
      provider = Class.new { include Syrus::Plugin::CoverageAnalyzer }

      expect(provider).to respond_to(:call)
      expect {
        provider.call(artifact_path: Pathname.new("coverage/lcov.info"), format_hint: "lcov")
      }.to raise_error(NotImplementedError, /must implement \.call/)
    end
  end

  describe ".providers_for" do
    it "returns an empty array when no providers are registered" do
      expect(described_class.providers_for(:prompt_injector)).to eq([])
    end

    it "returns a copy so callers cannot mutate the internal list" do
      described_class.providers_for(:prompt_injector) << double("interloper")
      expect(described_class.providers_for(:prompt_injector)).to eq([])
    end

    it "returns only classes registered for the requested extension point" do
      described_class.register(
        name: "multi_plugin", version: "1.0.0",
        provides: { agent_provider: agent_provider_class, chat_provider: chat_provider_class, mcp_tool_set: mcp_tool_set_class }
      )

      expect(described_class.providers_for(:agent_provider)).to eq([ agent_provider_class ])
      expect(described_class.providers_for(:chat_provider)).to eq([ chat_provider_class ])
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

    it "returns preview providers" do
      described_class.register(
        name: "preview_plugin", version: "1.0.0",
        provides: { preview_provider: preview_provider_class }
      )

      expect(described_class.providers_for(:preview_provider)).to eq([ preview_provider_class ])
    end

    it "returns admin page and chat MCP providers" do
      described_class.register(
        name: "ui_plugin", version: "1.0.0",
        provides: { admin_page: admin_page_class, chat_mcp_tool_set: chat_mcp_tool_set_class }
      )

      expect(described_class.providers_for(:admin_page)).to eq([ admin_page_class ])
      expect(described_class.providers_for(:chat_mcp_tool_set)).to eq([ chat_mcp_tool_set_class ])
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

    it "includes non-disableable providers even if a stale row says disabled" do
      described_class.register(
        name: "required_plugin",
        version: "1.0.0",
        disableable: false,
        provides: { agent_provider: agent_provider_class }
      )
      PluginRecord.where(name: "required_plugin").update_all(enabled: false)

      expect(described_class.providers_for(:agent_provider)).to eq([ agent_provider_class ])
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
            chat_provider:      chat_provider_class,
            mcp_tool_set:       mcp_tool_set_class,
            input_source:       input_source_class,
            test_result_parser: test_result_parser_class,
            coverage_analyzer:  coverage_analyzer_class,
            preview_provider:   preview_provider_class,
            admin_page:         admin_page_class,
            chat_mcp_tool_set:  chat_mcp_tool_set_class,
            source_control_provider: source_control_provider_class,
            artifact_renderer:  artifact_renderer_class
          }
        )
      }.not_to raise_error
    end

    it "accepts an array of artifact_renderer classes (multiple renderers per plugin)" do
      second_renderer = Class.new { include Syrus::Plugin::ArtifactRenderer }

      expect {
        described_class.register(
          name: "multi_renderer_plugin", version: "1.0.0",
          provides: { artifact_renderer: [ artifact_renderer_class, second_renderer ] }
        )
      }.not_to raise_error

      expect(described_class.providers_for(:artifact_renderer))
        .to contain_exactly(artifact_renderer_class, second_renderer)
    end

    it "raises RegistrationError when artifact_renderer class lacks the interface module" do
      plain_class = Class.new

      expect {
        described_class.register(
          name: "bad_plugin", version: "1.0.0",
          provides: { artifact_renderer: plain_class }
        )
      }.to raise_error(described_class::RegistrationError, /must include Syrus::Plugin::ArtifactRenderer/)
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

    it "raises RegistrationError when chat_provider class lacks the interface module" do
      plain_class = Class.new

      expect {
        described_class.register(
          name: "bad_plugin", version: "1.0.0",
          provides: { chat_provider: plain_class }
        )
      }.to raise_error(described_class::RegistrationError, /must include Syrus::Plugin::ChatProvider/)
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

    it "raises RegistrationError when preview_provider class lacks the interface module" do
      plain_class = Class.new

      expect {
        described_class.register(
          name: "bad_plugin", version: "1.0.0",
          provides: { preview_provider: plain_class }
        )
      }.to raise_error(described_class::RegistrationError, /must include Syrus::Plugin::PreviewProvider/)
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

      it "raises RegistrationError when a plugin claims a built-in workflow tool name" do
        set = make_tool_set("read_live_state")

        expect {
          described_class.register(name: "shadow_core", version: "1.0.0", provides: { mcp_tool_set: set })
        }.to raise_error(described_class::RegistrationError, /MCP tool name collision.*read_live_state/)
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

    it "creates a PluginRecord using the plugin default when none exists" do
      expect {
        described_class.register(name: "new_plugin", version: "1.0.0", default_enabled: false)
      }.to change { PluginRecord.where(name: "new_plugin", enabled: false, default_enabled: false).count }.by(1)
    end

    it "does not flip enabled on an existing PluginRecord" do
      PluginRecord.create!(name: "existing_plugin", enabled: false, default_enabled: false)
      described_class.register(name: "existing_plugin", version: "1.0.0", default_enabled: true)
      expect(PluginRecord.find_by!(name: "existing_plugin").enabled).to be(false)
    end

    it "forces non-disableable plugin records enabled" do
      described_class.register(name: "required_plugin", version: "1.0.0", default_enabled: false, disableable: false)

      record = PluginRecord.find_by!(name: "required_plugin")
      expect(record).to have_attributes(enabled: true, default_enabled: false, disableable: false)
    end

    it "is resilient when the plugin_records table does not exist" do
      allow(PluginRecord).to receive(:find_or_initialize_by).and_raise(ActiveRecord::StatementInvalid)
      expect {
        described_class.register(name: "resilient_plugin", version: "1.0.0")
      }.not_to raise_error
      expect(described_class.all_plugins.map(&:name)).to include("resilient_plugin")
    end

    it "is resilient when the database is unavailable during boot" do
      allow(PluginRecord).to receive(:find_or_initialize_by).and_raise(ActiveRecord::ConnectionNotEstablished)
      expect {
        described_class.register(name: "boot_plugin", version: "1.0.0")
      }.not_to raise_error
      expect(described_class.all_plugins.map(&:name)).to include("boot_plugin")
    end

    context "direct registration (register(:extension_point, provider))" do
      it "registers a provider for a known extension point" do
        provider = double("provider")
        described_class.register(:prompt_injector, provider)
        expect(described_class.providers_for(:prompt_injector)).to eq([ provider ])
      end

      it "accumulates multiple providers in registration order" do
        first  = double("first")
        second = double("second")
        described_class.register(:prompt_injector, first)
        described_class.register(:prompt_injector, second)
        expect(described_class.providers_for(:prompt_injector)).to eq([ first, second ])
      end

      it "raises ArgumentError for unknown extension points" do
        expect { described_class.register(:unknown_point, double) }
          .to raise_error(ArgumentError, /Unknown extension point/)
      end
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

    it "clears all registered providers" do
      described_class.register(:prompt_injector, double("provider"))
      described_class.reset!
      expect(described_class.providers_for(:prompt_injector)).to eq([])
    end
  end

  describe "Manifest" do
    it "is a Data object with registration metadata and enabled state" do
      described_class.register(
        name:        "manifest_plugin",
        display_name: "Manifest Plugin",
        version:     "3.0.0",
        custom_key:  "value",
        description: "Desc",
        homepage:    "https://example.com",
        default_enabled: false,
        disableable: true,
        category: "dev"
      )
      manifest = described_class.all_plugins.first

      expect(manifest).to be_a(Syrus::Plugin::Manifest)
      expect(manifest.name).to eq("manifest_plugin")
      expect(manifest.display_name).to eq("Manifest Plugin")
      expect(manifest.version).to eq("3.0.0")
      expect(manifest.provides).to eq({})
      expect(manifest.metadata).to eq({ custom_key: "value" })
      expect(manifest.description).to eq("Desc")
      expect(manifest.homepage).to eq("https://example.com")
      expect(manifest.icon_url).to be_nil
      expect(manifest.enabled).to be(false)
      expect(manifest.default_enabled).to be(false)
      expect(manifest.disableable).to be(true)
      expect(manifest.category).to eq("dev")
    end

    it "exposes enabled? as a boolean predicate" do
      described_class.register(name: "pred_plugin", version: "1.0.0")
      manifest = described_class.all_plugins.first
      expect(manifest.enabled?).to be(true)
    end
  end

  describe "Manifest home_queue and tick_interval" do
    it "defaults home_queue to :default" do
      described_class.register(name: "tick_plugin", version: "1.0.0")
      expect(described_class.all_plugins.first.home_queue).to eq(:default)
    end

    it "stores a custom home_queue on the manifest" do
      described_class.register(name: "tick_plugin", version: "1.0.0", home_queue: :control_plane)
      expect(described_class.all_plugins.first.home_queue).to eq(:control_plane)
    end

    it "defaults tick_interval to nil" do
      described_class.register(name: "tick_plugin", version: "1.0.0")
      expect(described_class.all_plugins.first.tick_interval).to be_nil
    end

    it "stores a tick_interval on the manifest" do
      described_class.register(name: "tick_plugin", version: "1.0.0", tick_interval: 5.minutes)
      expect(described_class.all_plugins.first.tick_interval).to eq(5.minutes)
    end
  end

  describe ".fire_boot_callbacks!" do
    let(:callbacks_class) do
      Class.new do
        include Syrus::Plugin::Callbacks
        def self.on_boot = @booted = true
        def self.booted? = @booted
      end
    end

    it "calls on_boot on enabled callback providers" do
      described_class.register(name: "boot_plugin", version: "1.0.0", provides: { callbacks: callbacks_class })

      described_class.fire_boot_callbacks!

      expect(callbacks_class.booted?).to be(true)
    end

    it "does not call on_boot on disabled plugins" do
      disabled_callbacks = Class.new do
        include Syrus::Plugin::Callbacks
        def self.on_boot = @booted = true
        def self.booted? = @booted
      end

      described_class.register(name: "disabled_boot_plugin", version: "1.0.0", provides: { callbacks: disabled_callbacks })
      PluginRecord.find_by!(name: "disabled_boot_plugin").update!(enabled: false)

      described_class.fire_boot_callbacks!

      expect(disabled_callbacks.booted?).to be_falsey
    end

    it "logs and continues when a provider raises on_boot" do
      raising_callbacks = Class.new do
        include Syrus::Plugin::Callbacks
        def self.on_boot = raise "boot error"
      end

      described_class.register(name: "raising_plugin", version: "1.0.0", provides: { callbacks: raising_callbacks })
      allow(Rails.logger).to receive(:warn)

      expect { described_class.fire_boot_callbacks! }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/on_boot failed/)
    end
  end

  describe ".registered_names" do
    it "returns registered plugin names without consulting PluginRecord state" do
      described_class.register(name: "plugin_a", version: "1.0.0")
      allow(PluginRecord).to receive(:all).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect(described_class.registered_names).to eq([ "plugin_a" ])
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
end
