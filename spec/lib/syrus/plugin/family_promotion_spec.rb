require "rails_helper"

RSpec.describe Syrus::Plugin::FamilyPromotion do
  before do
    Syrus::Plugin::Family.reset!
    Syrus::Plugin::Family.define(:promotion_fixture) do
      shape :facet
      capability :items, composition: :collect, absent: [], tier: :stable, context: Object, returns: Array
    end
  end

  after { Syrus::Plugin::Family.reset! }

  def manifest(name)
    declaration = Syrus::Plugin::FamilyDeclaration.build(
      family: :promotion_fixture, provider: "#{name.camelize}::Provider", implements: %i[items]
    )
    Syrus::Plugin::Manifest.new(name:, version: "1.0.0", provides: {}, family_provides: [ declaration ], metadata: {})
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
end
