require "rails_helper"

RSpec.describe Syrus::Plugin::Family do
  around do |example|
    described_class.reset!
    example.run
    described_class.reset!
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
    expect(family.capabilities.fetch(:detect_prepare)).to have_attributes(composition: :collect, absent: [], tier: :stable, context: "PrepareContext")
  end

  it "rejects missing shapes, duplicate capabilities, and unsupported contract values" do
    expect { described_class.define(:empty) { capability :x, composition: :collect, absent: [], tier: :stable, context: Object } }
      .to raise_error(ArgumentError, /declare a shape/)
    expect do
      described_class.define(:bad) { shape :facet; capability :x, composition: :merge, absent: nil, tier: :stable, context: Object }
    end.to raise_error(ArgumentError, /Unknown composition/)
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
end
