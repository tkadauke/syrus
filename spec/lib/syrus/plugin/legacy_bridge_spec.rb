require "rails_helper"

RSpec.describe Syrus::Plugin::LegacyBridge, :reset_plugin_registry do
  before do
    Syrus::PluginRegistry.reset!
    Syrus::Plugin::Family.reset!
    adapter = Module.new do
      module_function
      def detect?(provider, repo_path) = provider.detect_prepare(repo_path).any?
      def prepare_commands(provider, repo_path) = provider.detect_prepare(repo_path)
    end
    Syrus::Plugin::Family.define(:ecosystem_bridge_spec) do
      shape :facet
      capability :detect_prepare, composition: :collect, absent: [], tier: :stable, context: String, returns: Array
      legacy :prepare_detector, capability: :detect_prepare, adapter:
    end
  end

  after do
    Syrus::PluginRegistry.reset!
    Syrus::Plugin::Family.reset!
    Object.send(:remove_const, :LegacyBridgeSpec) if Object.const_defined?(:LegacyBridgeSpec)
  end

  def declaration(provider)
    Syrus::Plugin::FamilyDeclaration.build(
      family: :ecosystem_bridge_spec, provider:, implements: %i[detect_prepare]
    )
  end

  def family_provider(name, command)
    namespace = Object.const_defined?(:LegacyBridgeSpec) ? LegacyBridgeSpec : Object.const_set(:LegacyBridgeSpec, Module.new)
    namespace.const_set(name, Class.new do
      define_singleton_method(:key) { name.downcase.to_sym }
      define_singleton_method(:display_name) { name.to_s }
      define_singleton_method(:detect_prepare) { |_context| [ command ] }
    end)
    "LegacyBridgeSpec::#{name}"
  end

  it "merges family adapters and legacy registrations in plugin priority order" do
    family_name = family_provider(:FamilyProvider, "family prepare")
    legacy = Class.new do
      include Syrus::Plugin::PrepareDetector
      def self.detect?(_repo_path) = true
      def self.prepare_commands(_repo_path) = [ "legacy prepare" ]
    end
    Syrus::PluginRegistry.register(name: "legacy", version: "1", prepare_priority: 20,
      provides: { prepare_detector: legacy })
    Syrus::PluginRegistry.register(name: "family", version: "1", prepare_priority: 10,
      family_provides: [ declaration(family_name) ])

    providers = Syrus::PluginRegistry.providers_for(:prepare_detector)

    expect(providers.map { |provider| provider.prepare_commands("/repo") })
      .to eq([ [ "family prepare" ], [ "legacy prepare" ] ])
  end

  it "reports a plugin that registers both forms" do
    family_name = family_provider(:DuplicateProvider, "prepare")
    legacy = Class.new do
      include Syrus::Plugin::PrepareDetector
      def self.detect?(_repo_path) = false
      def self.prepare_commands(_repo_path) = []
    end
    Syrus::PluginRegistry.register(name: "duplicate", version: "1",
      provides: { prepare_detector: legacy }, family_provides: [ declaration(family_name) ])

    expect(Syrus::PluginRegistry.legacy_bridge_duplicate_registrations).to contain_exactly(
      have_attributes(plugin: "duplicate", family: :ecosystem_bridge_spec,
        extension_point: :prepare_detector, capability: :detect_prepare)
    )
  end
end
