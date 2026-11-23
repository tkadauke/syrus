require "rails_helper"

RSpec.describe Syrus::Plugin::ServiceProvider, :reset_plugin_registry do
  before { described_class.restore_definitions! }
  let!(:baseline) { described_class::FAMILY_FOR.keys.to_h { |capability| [ capability, described_class.providers(capability) ] } }

  def added(capability) = described_class.providers(capability) - baseline.fetch(capability)

  def declare(plugin, family, provider_name, capabilities, priority: 100)
    definition = Syrus::Plugin::Family.fetch(family)
    tiers = capabilities.group_by { |capability| definition.capabilities.fetch(capability).tier }
    Syrus::PluginRegistry.register(
      name: plugin, version: "1", provides: {}, prepare_priority: priority,
      family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
        family:, provider: provider_name, implements: tiers.fetch(:stable, []), provisional: tiers.fetch(:provisional, [])
      ) ]
    )
  end

  def service_class(key)
    Class.new do
      define_singleton_method(:provider_key) { key }
      define_singleton_method(:display_name) { key.titleize }
      define_singleton_method(:available?) { true }
    end
  end

  describe "family definitions" do
    it "declares the five service families with the issue's ownership" do
      expect(described_class::TIERS.transform_values(&:keys)).to eq(
        agent_runtime: %i[agent_provider chat_provider],
        execution_backend: %i[execution_backend],
        runtime_session: %i[runtime_session_provider],
        source_host: %i[source_control_provider input_source repository_content_provider workspace_git_transport],
        speech_to_text: %i[speech_to_text_provider]
      )
    end

    it "uses the service shape with available_for? as required core" do
      described_class::TIERS.each_key do |family|
        definition = Syrus::Plugin::Family.fetch(family)
        expect(definition.shape).to eq(:service)
        expect(definition.required_core).to eq(%i[key display_name available_for?])
        expect(definition.legacy_mappings.keys).to eq(definition.capabilities.keys)
      end
    end

    it "marks a capability stable only when two bundled plugins implement it" do
      stable = described_class::TIERS.flat_map { |family, tiers| tiers.select { |_c, tier| tier == :stable }.keys.map { |c| [ family, c ] } }
      expect(stable).to contain_exactly(
        %i[agent_runtime agent_provider], %i[agent_runtime chat_provider], %i[runtime_session runtime_session_provider],
        %i[source_host input_source], %i[source_host repository_content_provider]
      )
      expect(Syrus::Plugin::FamilyPromotion.new(definitions: described_class::DEFINITIONS.values).violations).to be_empty
    end

    it "keeps the service interface modules as the contract and gives the families one lookup" do
      expect(described_class::FAMILY_FOR.keys).to match_array(
        Syrus::PluginRegistry::INTERFACE_FOR.keys & described_class::FAMILY_FOR.keys
      )
    end
  end

  describe ".build" do
    it "resolves constants lazily and includes the service interface" do
      klass = Class.new { def self.provider_key = "lazy" }
      stub_const("LazyAgent", klass)
      provider = described_class.build(key: "acme", display_name: "Acme", agent_provider: "LazyAgent")

      expect(provider.key).to eq("acme")
      expect(provider.available_for?(Syrus::Plugin::Context::ServiceContext.new)).to be(true)
      expect(provider.available_for?(Syrus::Plugin::Context::ServiceContext.new(enabled: false))).to be(false)
      expect(provider.agent_provider(Syrus::Plugin::Context::ServiceContext.new)).to eq(klass)
      expect(klass.ancestors).to include(Syrus::Plugin::AgentProvider)
      expect(provider.agent_provider(Syrus::Plugin::Context::ServiceContext.new(enabled: false))).to be_nil
      expect(provider.owns_implementation?(klass.new)).to be(true)
    end

    it "rejects a capability that no service family owns" do
      expect { described_class.build(key: "x", display_name: "X", nonsense: "Nope") }.to raise_error(ArgumentError, /Unknown service capability/)
    end
  end

  describe "dispatch and the legacy bridge" do
    it "returns family-declared services in plugin priority order" do
      late, early = service_class("late"), service_class("early")
      stub_const("LateAgent", late)
      stub_const("EarlyAgent", early)
      stub_const("LateDecl", described_class.build(key: "late", display_name: "Late", agent_provider: "LateAgent"))
      stub_const("EarlyDecl", described_class.build(key: "early", display_name: "Early", agent_provider: "EarlyAgent"))
      declare("late_plugin", :agent_runtime, "LateDecl", %i[agent_provider], priority: 200)
      declare("early_plugin", :agent_runtime, "EarlyDecl", %i[agent_provider], priority: 50)

      expect(added(:agent_provider)).to eq([ early, late ])
    end

    it "shows family declarations to legacy readers through the bridge" do
      klass = service_class("bridged")
      stub_const("BridgedAgent", klass)
      stub_const("BridgedDecl", described_class.build(key: "bridged", display_name: "Bridged", agent_provider: "BridgedAgent"))
      declare("bridged_plugin", :agent_runtime, "BridgedDecl", %i[agent_provider])

      expect(Syrus::PluginRegistry.providers_for(:agent_provider) - baseline.fetch(:agent_provider)).to eq([ klass ])
    end

    it "shows legacy registrations to dispatch" do
      klass = service_class("legacy")
      klass.include(Syrus::Plugin::AgentProvider)
      Syrus::PluginRegistry.register(name: "legacy_agent", version: "1", provides: { agent_provider: klass })

      expect(added(:agent_provider)).to eq([ klass ])
    end

    it "reports a plugin that registers one service both ways" do
      klass = service_class("doubled")
      klass.include(Syrus::Plugin::AgentProvider)
      stub_const("DoubledAgent", klass)
      stub_const("DoubledDecl", described_class.build(key: "doubled", display_name: "Doubled", agent_provider: "DoubledAgent"))
      Syrus::PluginRegistry.register(
        name: "doubled_plugin", version: "1", provides: { agent_provider: klass },
        family_provides: [ Syrus::Plugin::FamilyDeclaration.build(family: :agent_runtime, provider: "DoubledDecl", implements: %i[agent_provider]) ]
      )

      expect(Syrus::PluginRegistry.legacy_bridge_duplicate_registrations.map(&:extension_point)).to include(:agent_provider)
    end

    it "keeps every service point reachable through both lookups" do
      described_class::FAMILY_FOR.each do |capability, family|
        expect(Syrus::Plugin::Family.fetch(family).legacy_mappings.keys).to include(capability)
        expect(described_class.providers(capability)).to be_an(Array)
      end
    end

    it "withholds a family service when its plugin is unhealthy for conformance" do
      stub_const("BadDecl", Class.new { def self.key = "bad" })
      declare("bad_plugin", :agent_runtime, "BadDecl", %i[agent_provider])

      expect(added(:agent_provider)).to be_empty
    end
  end

  describe ".for_manifest" do
    it "reads legacy and family contributions of one manifest" do
      klass = service_class("manifest")
      stub_const("ManifestAgent", klass)
      stub_const("ManifestDecl", described_class.build(key: "manifest", display_name: "Manifest", agent_provider: "ManifestAgent"))
      declare("manifest_plugin", :agent_runtime, "ManifestDecl", %i[agent_provider])
      manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "manifest_plugin" }

      expect(described_class.for_manifest(manifest, :agent_provider)).to eq([ klass ])
      expect(described_class.for_manifest(manifest, :chat_provider)).to eq([])
    end
  end

  describe "selection stays with the services" do
    it "keeps the Execution::Router claim loop over family-declared backends" do
      claiming = Class.new do
        include Syrus::Plugin::ExecutionBackend
        def self.available_for?(_request) = true
        def run(_request) = :ran
      end
      declining = Class.new do
        include Syrus::Plugin::ExecutionBackend
        def self.available_for?(_request) = false
      end
      stub_const("ClaimingBackend", claiming)
      stub_const("DecliningBackend", declining)
      stub_const("ClaimingDecl", described_class.build(key: "claiming", display_name: "Claiming", execution_backend: "ClaimingBackend"))
      stub_const("DecliningDecl", described_class.build(key: "declining", display_name: "Declining", execution_backend: "DecliningBackend"))
      declare("declining_plugin", :execution_backend, "DecliningDecl", %i[execution_backend], priority: 10)
      declare("claiming_plugin", :execution_backend, "ClaimingDecl", %i[execution_backend], priority: 20)
      request = Struct.new(:workload_policy).new(nil)

      expect(Execution::Router.new.send(:backend_for, request)).to be_a(claiming)
    end

    it "keeps AgentProviders.for selecting by provider key" do
      first, second = service_class("first"), service_class("second")
      stub_const("FirstAgent", first)
      stub_const("SecondAgent", second)
      stub_const("TwoDecl", described_class.build(key: "two", display_name: "Two", agent_provider: [ "FirstAgent", "SecondAgent" ]))
      declare("two_plugin", :agent_runtime, "TwoDecl", %i[agent_provider])

      expect(AgentProviders.for("second")).to eq(second)
      expect { AgentProviders.for("third") }.to raise_error(AgentProviders::ConfigurationError)
    end
  end
end
