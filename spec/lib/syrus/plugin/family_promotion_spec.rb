require "rails_helper"

RSpec.describe Syrus::Plugin::FamilyPromotion do
  before do
    Syrus::Plugin::Family.reset!
    Syrus::Plugin::Family.define(:promotion_fixture) do
      shape :facet
      capability :items, composition: :collect, absent: [], tier: :stable, context: Object, returns: Array
    end
  end

  after { Syrus::Plugin::Family.restore_built_ins! }

  def manifest(name)
    declaration = Syrus::Plugin::FamilyDeclaration.build(
      family: :promotion_fixture, provider: "#{name.camelize}::Provider", implements: %i[items]
    )
    Syrus::Plugin::Manifest.new(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name:, version: "1.0.0", provides: {}, family_provides: [ declaration ], metadata: {})
  end

  it "permits stable capabilities with two independent implementations and a contract" do
    promotion = described_class.new(manifests: [ manifest("one"), manifest("two") ])
    expect(promotion.violations).to be_empty
  end

  it "rejects stable capabilities missing implementation or contract evidence" do
    implementations = described_class.new(manifests: [ manifest("one") ])
    expect(implementations.violations.first.message).to include("1 independent in-tree implementation")

    contracts = described_class.new(manifests: [ manifest("one"), manifest("two") ], contracted_capabilities: Set.new)
    expect(contracts.violations.first.message).to include("no generated contract test")
  end

  it "counts mapped legacy registrations while a family is migrating" do
    definition = Syrus::Plugin::Family.fetch(:promotion_fixture)
    adapter = Module.new
    definition.legacy(:legacy_items, capability: :items, adapter:)
    legacy = ->(name) do
      Syrus::Plugin::Manifest.new(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name:, version: "1.0.0", provides: { legacy_items: Object.new },
        family_provides: [], metadata: {})
    end

    promotion = described_class.new(manifests: [ legacy.call("one"), legacy.call("two") ])
    expect(promotion.violations).to be_empty
  end
end
