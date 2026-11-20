require "rails_helper"

RSpec.describe Syrus::Plugin::Family do
  around do |example|
    described_class.reset!
    begin
      example.run
    ensure
      described_class.reset!
    end
  end

  def define_family
    described_class.define(:ecosystem) do
      shape :facet
      capability :detect_prepare, composition: :collect, absent: [], tier: :stable, context: "PrepareContext"
      capability :prompt_context, composition: :first_claim, absent: nil, tier: :provisional, context: "PromptContext"
    end
  end

  it "records shape, required core, and capability contracts" do
    family = define_family
    expect(family.required_core).to eq(%i[key display_name])
    expect(family.capabilities.fetch(:detect_prepare)).to have_attributes(
      composition: :collect, absent: [], tier: :stable, context: "PrepareContext",
      method_contract: have_attributes(required_positionals: 1, required_keywords: [], optional_keywords: [])
    )
    expect(family.core_method_contract(:key)).to have_attributes(required_positionals: 0)
  end

  it "rejects missing shapes, duplicate capabilities, and unsupported contract values" do
    expect { described_class.define(:empty) { capability :x, composition: :collect, absent: [], tier: :stable, context: Object } }
      .to raise_error(ArgumentError, /declare a shape/)
    expect do
      described_class.define(:bad) { shape :facet; capability :x, composition: :merge, absent: nil, tier: :stable, context: Object }
    end.to raise_error(ArgumentError, /Unknown composition/)
    expect do
      described_class.define(:duplicates) do
        shape :facet
        capability :x, composition: :collect, absent: [], tier: :stable, context: Object
        capability :x, composition: :collect, absent: [], tier: :stable, context: Object
      end
    end.to raise_error(ArgumentError, /Duplicate capability/)
    expect do
      described_class.define(:missing_context) do
        shape :facet
        capability :x, composition: :collect, absent: [], tier: :stable, context: nil
      end
    end.to raise_error(ArgumentError, /context contract is required/)

    define_family
    expect { define_family }.to raise_error(ArgumentError, /already defined/)
  end

  it "validates known capabilities, tiers, and duplicates at declaration time" do
    define_family
    expect do
      Syrus::Plugin::FamilyDeclaration.build(family: :ecosystem, provider: "Kotlin::Ecosystem", implements: %i[missing])
    end.to raise_error(ArgumentError, /Unknown capability/)
    expect do
      Syrus::Plugin::FamilyDeclaration.build(family: :ecosystem, provider: "Kotlin::Ecosystem", implements: %i[prompt_context])
    end.to raise_error(ArgumentError, /provisional, not stable/)
    expect do
      Syrus::Plugin::FamilyDeclaration.build(family: :ecosystem, provider: "Kotlin::Ecosystem", implements: %i[detect_prepare detect_prepare])
    end.to raise_error(ArgumentError, /Duplicate capabilities/)
  end

  it "requires manifest keys for keyed capabilities" do
    described_class.define(:resolver) do
      shape :facet
      capability :resolve, composition: :keyed, absent: "raises", tier: :stable, context: Object
    end

    expect do
      Syrus::Plugin::FamilyDeclaration.build(family: :resolver, provider: "Resolver", implements: %i[resolve])
    end.to raise_error(ArgumentError, /must declare its key/)
    expect(
      Syrus::Plugin::FamilyDeclaration.build(family: :resolver, provider: "Resolver", key: :ruby, implements: %i[resolve]).key
    ).to eq(:ruby)
  end
end
