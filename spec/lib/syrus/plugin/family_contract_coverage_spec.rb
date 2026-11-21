require "rails_helper"

RSpec.describe Syrus::Plugin::FamilyContractCoverage do
  before do
    Syrus::Plugin::Family.reset!
    Syrus::Plugin::Family.define(:coverage_fixture) do
      shape :facet
      capability :items, composition: :collect, absent: [], tier: :provisional,
        context: Object, returns: Array
    end
  end

  after do
    Syrus::Plugin::Family.reset!
  end

  def manifest(name, provider)
    declaration = Syrus::Plugin::FamilyDeclaration.build(
      family: :coverage_fixture, provider:, provisional: %i[items]
    )
    Syrus::Plugin::Manifest.new(
      name:, version: "1.0.0", provides: {}, family_provides: [ declaration ], metadata: {}
    )
  end

  it "tracks every plugin provider declaration independently" do
    manifests = [ manifest("one", "One::Provider"), manifest("two", "Two::Provider") ]

    declaration = described_class.declaration!(
      plugin: "one", family: :coverage_fixture, provider: "One::Provider", manifests:
    )

    expect(declaration.capabilities).to eq(%i[items])
    expect(described_class.missing(manifests:)).to contain_exactly(
      have_attributes(plugin: "two", family: :coverage_fixture, provider: "Two::Provider")
    )
  end

  it "rejects a shared example that does not identify an exact declaration" do
    manifests = [ manifest("one", "One::Provider") ]

    expect do
      described_class.declaration!(
        plugin: "one", family: :coverage_fixture, provider: "Other::Provider", manifests:
      )
    end.to raise_error(ArgumentError, /does not declare Other::Provider/)
  end
end
