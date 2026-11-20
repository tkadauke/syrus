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

  it "orders multiple conforming classes by plugin priority" do
    namespace = Object.const_set(:LazyFamilySpec, Module.new)
    %i[Early Late Second].each do |name|
      namespace.const_set(name, Class.new do
        def self.key = :provider
        def self.display_name = "Provider"
        def self.detect_prepare(context) = context
      end)
    end
    described_class.register(name: "late", version: "1", prepare_priority: 20,
      family_provides: [ declaration("LazyFamilySpec::Late"), declaration("LazyFamilySpec::Second") ])
    described_class.register(name: "early", version: "1", prepare_priority: 10,
      family_provides: [ declaration("LazyFamilySpec::Early") ])

    providers = described_class.capability_providers(:ecosystem, :detect_prepare)
    expect(providers.map(&:provider_name)).to eq(%w[LazyFamilySpec::Early LazyFamilySpec::Late LazyFamilySpec::Second])
    expect(described_class.capability_catalog(:ecosystem).map { |entry| entry[:provider] }).to eq(providers.map(&:provider_name))
  ensure
    Object.send(:remove_const, :LazyFamilySpec) if Object.const_defined?(:LazyFamilySpec)
  end

  it "resolves plugin availability once when building the whole catalog" do
    described_class.register(name: "provider", version: "1", family_provides: [ declaration("LazyFamilySpec::Provider") ])
    allow(described_class).to receive(:records_for).and_call_original

    described_class.capability_catalog

    expect(described_class).to have_received(:records_for).once
  end

  it "selects keyed providers from conforming manifest declarations" do
    namespace = Object.const_set(:LazyFamilySpec, Module.new)
    namespace.const_set(:Resolver, Class.new do
      def self.key = :ruby
      def self.display_name = "Resolver"
      def self.resolve(context) = context
    end)
    keyed = Syrus::Plugin::FamilyDeclaration.build(
      family: :ecosystem, provider: "LazyFamilySpec::Resolver", key: :ruby, implements: %i[resolve]
    )
    described_class.register(name: "resolver", version: "1", family_provides: [ keyed ])

    provider = described_class.capability_providers(:ecosystem, :resolve).sole
    expect(provider.key).to eq(:ruby)
  ensure
    Object.send(:remove_const, :LazyFamilySpec) if Object.const_defined?(:LazyFamilySpec)
  end

  it "loads a provider only when invoked and never returns a disabled plugin" do
    namespace = Object.const_set(:LazyFamilySpec, Module.new)
    namespace.const_set(:Enabled, Class.new do
      def self.key = :enabled
      def self.display_name = "Enabled"
      def self.detect_prepare(context) = context
    end)
    described_class.register(name: "enabled", version: "1", family_provides: [ declaration("LazyFamilySpec::Enabled") ])
    described_class.register(name: "disabled", version: "1", default_enabled: false,
      family_provides: [ declaration("LazyFamilySpec::Disabled") ])

    providers = described_class.capability_providers(:ecosystem, :detect_prepare)
    expect(providers.map(&:plugin_name)).to eq([ "enabled" ])
    expect(providers.first.invoke { |provider| provider }).to eq(LazyFamilySpec::Enabled)
  ensure
    Object.send(:remove_const, :LazyFamilySpec) if Object.const_defined?(:LazyFamilySpec)
  end

  it "reports missing capabilities and withholds only the non-conforming family" do
    namespace = Object.const_set(:ConformanceFamilySpec, Module.new)
    namespace.const_set(:Missing, Class.new do
      def self.key = :missing
      def self.display_name = "Missing"
    end)
    legacy = Class.new { include Syrus::Plugin::Callbacks }
    described_class.register(name: "missing", version: "1", provides: { callbacks: legacy },
      family_provides: [ declaration("ConformanceFamilySpec::Missing") ])

    expect(described_class.health.status("missing")).to have_attributes(
      state: :non_conforming,
      reasons: include("ConformanceFamilySpec::Missing does not define required method detect_prepare")
    )
    expect(described_class.capability_providers(:ecosystem, :detect_prepare)).to be_empty
    expect(described_class.providers_for(:callbacks)).to include(legacy)
  ensure
    Object.send(:remove_const, :ConformanceFamilySpec) if Object.const_defined?(:ConformanceFamilySpec)
  end

  it "reports wrong signatures, missing required core, and unknown capabilities" do
    namespace = Object.const_set(:ConformanceVariantsSpec, Module.new)
    namespace.const_set(:WrongSignature, Class.new do
      def self.key = :wrong
      def self.display_name = "Wrong"
      def self.detect_prepare(context:) = context
    end)
    namespace.const_set(:MissingCore, Class.new do
      def self.detect_prepare(context) = context
    end)
    namespace.const_set(:Unknown, Class.new do
      def self.key = :unknown
      def self.display_name = "Unknown"
      def self.future_capability(context) = context
    end)
    unknown = Syrus::Plugin::FamilyDeclaration.new(
      family: :ecosystem, provider: "ConformanceVariantsSpec::Unknown", key: nil,
      implements: [ :future_capability ], provisional: []
    )
    described_class.register(name: "wrong-signature", version: "1",
      family_provides: [ declaration("ConformanceVariantsSpec::WrongSignature") ])
    described_class.register(name: "missing-core", version: "1",
      family_provides: [ declaration("ConformanceVariantsSpec::MissingCore") ])
    described_class.register(name: "unknown", version: "1", family_provides: [ unknown ])

    expect(described_class.health.status("wrong-signature").reasons.join)
      .to include("1 required context argument(s), required keywords [], and optional keywords []")
    expect(described_class.health.status("missing-core").reasons).to include(
      "ConformanceVariantsSpec::MissingCore does not define required method key",
      "ConformanceVariantsSpec::MissingCore does not define required method display_name"
    )
    expect(described_class.health.status("unknown").reasons).to include(
      "ConformanceVariantsSpec::Unknown claims unknown ecosystem capability future_capability"
    )
  ensure
    Object.send(:remove_const, :ConformanceVariantsSpec) if Object.const_defined?(:ConformanceVariantsSpec)
  end

  it "accepts a conforming provider" do
    namespace = Object.const_set(:ConformingFamilySpec, Module.new)
    namespace.const_set(:Provider, Class.new do
      def self.key = :conforming
      def self.display_name = "Conforming"
      def self.detect_prepare(context) = context
    end)
    described_class.register(name: "conforming", version: "1",
      family_provides: [ declaration("ConformingFamilySpec::Provider") ])

    expect(described_class.health.status("conforming")).to be_ok
    expect(described_class.capability_providers(:ecosystem, :detect_prepare).map(&:plugin_name)).to eq([ "conforming" ])
  ensure
    Object.send(:remove_const, :ConformingFamilySpec) if Object.const_defined?(:ConformingFamilySpec)
  end

  it "does not load disabled providers while checking health" do
    described_class.register(name: "disabled", version: "1", default_enabled: false,
      family_provides: [ declaration("DisabledConformanceSpec::Provider") ])

    expect { described_class.health }.not_to change { Object.const_defined?(:DisabledConformanceSpec) }
    expect(described_class.health.status("disabled")).to be_ok
  end

  it "reports provider load errors without crashing health resolution" do
    described_class.register(name: "load-error", version: "1",
      family_provides: [ declaration("MissingConformanceSpec::Provider") ])

    expect { described_class.health }.not_to raise_error
    expect(described_class.health.status("load-error")).to have_attributes(
      state: :non_conforming,
      reasons: include(match(/could not load MissingConformanceSpec::Provider: NameError/))
    )
  end
end
