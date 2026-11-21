require "rails_helper"

RSpec.describe Syrus::PluginRegistry, :reset_plugin_registry do
  around do |example|
    described_class.reset!
    Syrus::Plugin::Family.reset!
    Syrus::Plugin::Family.define(:ecosystem) do
      shape :facet
      capability :detect_prepare, composition: :collect, absent: [], tier: :stable, context: "PrepareContext"
      capability :resolve, composition: :keyed, absent: "raises", tier: :stable, context: "ResolveContext"
    end
    begin
      example.run
    ensure
      described_class.reset!
      Syrus::Plugin::Family.reset!
    end
  end

  def declaration(provider)
    Syrus::Plugin::FamilyDeclaration.build(family: :ecosystem, provider:, implements: %i[detect_prepare])
  end

  it "keeps family class names in the manifest DSL without resolving them" do
    definition = Syrus::PluginApi::Definition.new(name: "kotlin", namespace: Module.new, lib_dir: __dir__)
    definition.provides ecosystem: "LazyFamilySpec::Kotlin", implements: %i[detect_prepare]

    expect(definition.manifest_arguments.fetch(:family_provides).first).to have_attributes(
      family: :ecosystem, provider: "LazyFamilySpec::Kotlin", implements: %i[detect_prepare]
    )
    expect(Object.const_defined?(:LazyFamilySpec)).to be(false)
  end

  it "records keyed selectors in the manifest DSL without resolving providers" do
    definition = Syrus::PluginApi::Definition.new(name: "resolver", namespace: Module.new, lib_dir: __dir__)
    definition.provides ecosystem: "LazyFamilySpec::Resolver", key: :ruby, implements: %i[resolve]

    expect(definition.manifest_arguments.fetch(:family_provides).first).to have_attributes(
      family: :ecosystem, provider: "LazyFamilySpec::Resolver", key: :ruby, implements: %i[resolve]
    )
    expect(Object.const_defined?(:LazyFamilySpec)).to be(false)
  end

  it "preserves key as a legacy provides entry outside family declarations" do
    definition = Syrus::PluginApi::Definition.new(name: "legacy", namespace: Module.new, lib_dir: __dir__)
    definition.provides key: "Legacy::Provider"

    expect(definition.provides).to eq(key: "Legacy::Provider")
  end

  it "orders multiple classes by plugin priority without loading them" do
    described_class.register(name: "late", version: "1", prepare_priority: 20,
      family_provides: [ declaration("LazyFamilySpec::Late"), declaration("LazyFamilySpec::Second") ])
    described_class.register(name: "early", version: "1", prepare_priority: 10,
      family_provides: [ declaration("LazyFamilySpec::Early") ])

    providers = described_class.capability_providers(:ecosystem, :detect_prepare)
    expect(providers.map(&:provider_name)).to eq(%w[LazyFamilySpec::Early LazyFamilySpec::Late LazyFamilySpec::Second])
    expect(Object.const_defined?(:LazyFamilySpec)).to be(false)
    expect(described_class.capability_catalog(:ecosystem).map { |entry| entry[:provider] }).to eq(providers.map(&:provider_name))
  end

  it "resolves plugin availability once when building the whole catalog" do
    described_class.register(name: "provider", version: "1", family_provides: [ declaration("LazyFamilySpec::Provider") ])
    allow(described_class).to receive(:records_for).and_call_original

    described_class.capability_catalog

    expect(described_class).to have_received(:records_for).once
  end

  it "selects keyed providers from manifest data without loading provider classes" do
    keyed = Syrus::Plugin::FamilyDeclaration.build(
      family: :ecosystem, provider: "LazyFamilySpec::Resolver", key: :ruby, implements: %i[resolve]
    )
    described_class.register(name: "resolver", version: "1", family_provides: [ keyed ])

    provider = described_class.capability_providers(:ecosystem, :resolve).sole
    expect(provider.key).to eq(:ruby)
    expect(Object.const_defined?(:LazyFamilySpec)).to be(false)
  end

  it "loads a provider only when invoked and never returns a disabled plugin" do
    described_class.register(name: "enabled", version: "1", family_provides: [ declaration("LazyFamilySpec::Enabled") ])
    described_class.register(name: "disabled", version: "1", default_enabled: false,
      family_provides: [ declaration("LazyFamilySpec::Disabled") ])

    providers = described_class.capability_providers(:ecosystem, :detect_prepare)
    expect(providers.map(&:plugin_name)).to eq([ "enabled" ])
    namespace = Object.const_set(:LazyFamilySpec, Module.new)
    namespace.const_set(:Enabled, Class.new)
    expect(providers.first.invoke { |provider| provider }).to eq(LazyFamilySpec::Enabled)
    Object.send(:remove_const, :LazyFamilySpec)
  end
end
